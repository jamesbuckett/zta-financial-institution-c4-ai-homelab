# Lab 5 — Posture Monitoring — Design

**Date:** 2026-04-26
**Scope:** Lab 5 only (`files/zta-homelab/labs/05-posture-monitoring/`). Labs 6–7 and the master install script are out of scope.
**Pattern source:** Labs 1–4.
**Snippet source:** `index.html` lines 4961–5562.

## Goal

Convert Lab 5's snippets in `index.html` into runnable scripts and manifests that follow the established pattern.

After running `00-posture-monitoring-install.sh`, the cluster has:
- Falco running as a DaemonSet with the modern_ebpf driver (verified — bootstrap-installed).
- A `cdm` Deployment + Service in `zta-runtime-security`: a Python webhook receiver that turns Falco events into pod-annotation patches (`zta.posture=tampered` for shell-in-container).
- `falco-falcosidekick` configured (via `helm upgrade`) to forward events to `cdm.zta-runtime-security.svc.cluster.local`.
- An `EnvoyFilter` + Lua HTTP filter on the api sidecar that projects the pod's `zta.posture` annotation onto an outbound `x-device-posture` header.
- The api Deployment patched with a downward-API env var `ZTA_POD_POSTURE` sourcing `metadata.annotations['zta.posture']`.
- A `posture-reconciler` CronJob (every 1 min) that bounces api pods whose env var no longer matches the annotation.
- A triggered "Terminal shell in container" detection that flowed: Falco → sidekick → CDM → annotation patch → reconciler bounce → new pod with `ZTA_POD_POSTURE=tampered`. Subsequent requests carry `x-device-posture: tampered` and Lab 4's policy denies them.

## Files to create

All files live in `files/zta-homelab/labs/05-posture-monitoring/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `01-verify.sh` | line 5107 | 4 narrative checks: DS ready=node count, modern_ebpf driver loaded, default rules include "Terminal shell in container", `/healthz` returns ok |
| `02-cdm.yaml` | line 5136 | Six resources: ServiceAccount, ClusterRole, ClusterRoleBinding, ConfigMap (Python `app.py`), Deployment, Service |
| `02-verify.sh` | line 5221 | 3 narrative check groups: deploy 1/1 + svc 80/8080, RBAC verbs are `get/list/patch/watch` + can-i patch yes / can-i delete no, POST synthetic event returns 204 |
| `03-falcosidekick.sh` | line 5257 | `helm upgrade --install falco falcosecurity/falco …` (NEW — wires webhook to CDM) |
| `03-verify.sh` | line 5270 | 3 narrative checks: sidekick 1/1, `WEBHOOK_ADDRESS` env equals CDM URL, `WEBHOOK_MINIMUMPRIORITY=notice`, end-to-end smoke (POST to sidekick → CDM logs PATCHED) |
| `04-posture-header.yaml` | line 5302 | `EnvoyFilter` (Lua adds `x-device-posture`) + api Deployment patch (downward API env `ZTA_POD_POSTURE`) |
| `04-verify.sh` | line 5354 | 4 narrative checks: EnvoyFilter inserts Lua, Lua source contains `x-device-posture`, downward API env points to `metadata.annotations['zta.posture']`, frontend wget shows non-`missing` `X-Device-Posture` |
| `05-reconciler.yaml` | line 5387 | CronJob `posture-reconciler` (every minute, runs as `cdm` SA, bounces drifted pods) |
| `05-verify.sh` | line 5427 | 3 narrative checks: schedule `*/1 * * * *`, SA = `cdm`, end-to-end (annotate `zta.posture=suspect`, wait ≤75 s, confirm new pod's env-var spec resolves to the annotation) |
| `06-trigger-detection.sh` | line 5462 | `kubectl exec api-pod -c httpbin -- sh -c 'exit 0'` to fire the rule |
| `06-verify.sh` | line 5489 | 4 narrative checks: Falco emitted "Terminal shell in container" with priority/ns, CDM logs `PATCHED ... posture=tampered`, pod annotation now `tampered` w/ rule + at, frontend wget shows `x-device-posture: tampered` |
| `07-break-it.sh` | line 5546 | Manual exercise (NOT run by install): set `WEBHOOK_ADDRESS=''`, repeat shell, observe annotation does NOT change |
| `00-posture-monitoring-install.sh` | — | Orchestrator with pauses; mirrors Lab 1–4 pattern |
| `verify.sh` | line 5519 | Umbrella pass/fail; combines step assertions + the doc's "validate Lab 5" block (403 + decision-id `device-tampered`) |

## Orchestrator behaviour

Mirrors Lab 4 structure exactly. `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab05)`.

### Step functions

1. `step_01_falco` — runs `01-verify.sh`. No apply.
2. `step_02_cdm` — `kubectl apply` `02-cdm.yaml`, `rollout status deploy/cdm -n zta-runtime-security --timeout=180s`, then `02-verify.sh`. The `python:3.12-alpine` image runs `pip install kubernetes==30.1.0` on first start, so the rollout-status timeout is generous (180 s, matches the doc).
3. `step_03_sidekick` — runs `bash 03-falcosidekick.sh` (the helm upgrade). Then `03-verify.sh`. **Prereq:** `helm` CLI on PATH; `falcosecurity` repo added (the orchestrator pre-checks both and aborts cleanly if missing, with a one-line install hint).
4. `step_04_posture_header` — `kubectl apply` `04-posture-header.yaml`, `rollout status deploy/api -n bookstore-api --timeout=180s`, then `04-verify.sh`.
5. `step_05_reconciler` — `kubectl apply` `05-reconciler.yaml`, then `05-verify.sh`. The verify mutates pod state (annotates suspect, waits 75 s) — this is intentional and matches the doc.
6. `step_06_trigger` — runs `bash 06-trigger-detection.sh`. Then **sleeps 90 s with a visible countdown** (Falco event → sidekick → CDM patch → reconciler tick → new pod with refreshed env). Then runs `06-verify.sh`.

After all steps: `echo "Lab 5 install completed successfully."`

## Special handling

### Helm prerequisite (step 03)

Step 03 uses `helm upgrade --install` against the `falcosecurity/falco` chart at version `4.8.1`. The orchestrator pre-checks:

```bash
command -v helm >/dev/null || { echo "ERROR: helm not on PATH"; exit 1; }
helm repo list | awk '{print $1}' | grep -qx falcosecurity || {
  echo "ERROR: helm repo 'falcosecurity' not added. Run:"
  echo "  helm repo add falcosecurity https://falcosecurity.github.io/charts"
  echo "  helm repo update"
  exit 1
}
```

If bootstrap installed Falco with custom values, `--reuse-values` is intentionally NOT used (matches the doc) — the doc's command provides a complete value set. Custom bootstrap values would be lost. If that's a problem in real deployment, swap to `--reuse-values --set falcosidekick.config.webhook.address=...`. This design matches the doc verbatim.

### Lua filter ordering (step 04)

The doc's `EnvoyFilter` uses `applyTo: HTTP_FILTER`, `match.context: SIDECAR_INBOUND`, `match.listener.filterChain.filter.name: envoy.filters.network.http_connection_manager`, `patch.operation: INSERT_BEFORE`. This inserts the Lua filter into the HCM's HTTP filter chain at the beginning — i.e., the Lua adds `x-device-posture` *before* the ext_authz filter (Lab 4) sees the request, so OPA reads the projected header. Matches the doc.

### Step 06 90 s wait

Sequence after `06-trigger-detection.sh`:
- Falco emits event (~5 s)
- Falcosidekick forwards to CDM webhook (~5 s)
- CDM patches pod annotation (~10 s total)
- Reconciler CronJob next tick (≤60 s)
- New pod scheduled + reaches Ready (~30 s)

Total ≤90 s. The orchestrator sleeps 90 s with `printf '\rwaiting %d / 90s' "$i"` then runs `06-verify.sh`.

### State left after Lab 5

The api pod has `zta.posture=tampered` after Lab 5 completes. Lab 6 (strict enforcement) and Lab 7 (telemetry) inherit this state. The umbrella `verify.sh` asserts the end state; the break-it (`07-break-it.sh`) shows what a CDM outage looks like.

### Lab 3 dependency for the umbrella's "validate Lab 5" assertions

The doc's validation block sources `labs/03-per-session/.env`, acquires a token, calls the api expecting 403, then checks OPA logs. Mirrored in `verify.sh` via `$SCRIPT_DIR/../03-per-session/.env`.

## Idempotency

- All `kubectl apply` calls use `--server-side --field-manager=zta-lab05`.
- `helm upgrade --install` is idempotent.
- `kubectl annotate --overwrite` is idempotent (replaces).
- The trigger in step 06 is idempotent in effect: re-running just creates more Falco events; the annotation stays `tampered`.
- The CronJob will keep ticking; it's a no-op if the env matches the annotation.

## Out of scope

- Bootstrap (assumed to have created Falco DaemonSet, the `zta-runtime-security` namespace, and `helm repo add falcosecurity`).
- Labs 1–4 (Lab 4 in particular — the policy that produces the 403 in the umbrella's validation assertions).
- Master install across all 7 labs.
- Break-it cleanup is manual (the doc provides `helm upgrade --reuse-values` to repair).

## Acceptance criteria

After running `00-posture-monitoring-install.sh` on a cluster with bootstrap + Labs 1–4 already applied:

1. The orchestrator completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. `kubectl -n zta-runtime-security get deploy cdm` reports `1/1`.
4. `kubectl -n zta-runtime-security get deploy falco-falcosidekick` reports `1/1`.
5. `kubectl -n bookstore-api get envoyfilter project-posture-header` exists with the Lua filter.
6. `kubectl -n zta-runtime-security get cronjob posture-reconciler` exists with schedule `*/1 * * * *`.
7. The api pod's annotation `zta.posture` is `tampered` (after step 06 completed).
8. A frontend → api wget shows `X-Device-Posture: tampered`.
9. The Lab 4 policy denies a request from the frontend (HTTP 403, OPA decision reason `device-tampered`).
10. Re-running the orchestrator on the same cluster does not error out.

## File-by-file source mapping

YAML files are **verbatim** from `index.html` `<pre><code>` blocks (HTML entities decoded). Bash scripts are verbatim with one specific edit: `06-trigger-detection.sh` uses `kubectl exec` (not `kubectl exec -it`) since the orchestrator runs it without a TTY (the doc shows `-it` for human use; we drop `-t` so it works under `bash`).

The umbrella `verify.sh` adapts the doc's "validate Lab 5" block — `source labs/03-per-session/.env` becomes `source "$SCRIPT_DIR/../03-per-session/.env"`.

Per-step verify scripts follow the narrative pattern (no shebang, no `set -e`, but `chmod +x`). The umbrella is the strict pass/fail script using the `check` helper.

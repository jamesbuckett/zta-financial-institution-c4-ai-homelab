# Lab 7 — Telemetry Loop — Design

**Date:** 2026-04-26
**Scope:** Lab 7 only (`files/zta-homelab/labs/07-telemetry-loop/`). Master install script is the next-and-final piece of work, separate session.
**Pattern source:** Labs 1–6.
**Snippet source:** `index.html` lines 6201–6853.

## Goal

Convert Lab 7's snippets into runnable scripts and manifests that follow the established pattern.

After running `00-telemetry-loop-install.sh`, the cluster has:
- A `Service` `opa-metrics` exposing OPA's diagnostic port + a `ServiceMonitor` so kube-prometheus scrapes it.
- A `grafana-agent` DaemonSet tailing OPA logs into Loki, with a JSON pipeline that promotes `decision_id`, `allow`, `reason`, `path`, `method`, `posture` to Loki labels.
- An Istio mesh-root `Telemetry` resource enabling 100% trace sampling to a new `otel-tempo` extension provider; the `istio-system/istio` ConfigMap registers BOTH `opa-ext-authz` (preserved from Lab 4) and `otel-tempo`.
- A Grafana dashboard `zta-main` (4 panels: decision rate, P50/P99 latency, deny reasons, recent denies log) loaded via the `grafana_dashboard: "1"` ConfigMap label.
- A driven 200-request load mix producing >=200 OPA decisions and exercising all three posture values.
- A refined Rego policy (split `no-matching-allow` into `missing-token` / `invalid-subject` / `no-matching-allow`) republished via Lab 6's PA → signed bundle → OPA, demonstrating the T7 feedback loop closing.

## Files to create

All files in `files/zta-homelab/labs/07-telemetry-loop/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `01-opa-servicemonitor.yaml` | line 6354 | Service `opa-metrics` (port 8282) + ServiceMonitor `opa` with `release=kube-prom` |
| `01-verify.sh` | line 6389 | 4 narrative checks: Service ports + endpoints, ServiceMonitor release label, Prom target up, OPA `/metrics` has `^opa_` lines |
| `02-grafana-agent.yaml` | line 6423 | ConfigMap `grafana-agent-config` (with the agent.yaml pipeline) + DaemonSet `grafana-agent` |
| `02-verify.sh` | line 6494 | 4 narrative checks: DS ready=node count, agent points to Loki, pipeline promotes decision_id/allow/reason, Loki shows `namespace` label |
| `03-istio-tracing.yaml` | line 6529 | Mesh-root `Telemetry` (otel-tempo, 100% sample) + `istio-system/istio` ConfigMap with BOTH providers |
| `03-verify.sh` | line 6564 | 3 narrative checks: Telemetry resource correct, mesh config has both providers, Tempo records traces from ingress |
| `04-dashboard.yaml` | line 6603 | ConfigMap `zta-dashboard` with `grafana_dashboard: "1"` label, embedded JSON (4 panels) |
| `04-verify.sh` | line 6656 | 3 narrative checks: ConfigMap has the label, JSON has exactly 4 panels with the documented titles, Grafana UID `zta-main` reachable |
| `05-load-mix.sh` | line 6688 | Drives 200 random posture/method requests to api |
| `05-verify.sh` | line 6722 | 3 narrative checks: >=200 decisions in 5 min, all three posture values present in Loki, P99 < 10 ms |
| `06-zta.authz.rego` | line 4504 + diff at 6757 | Refined Rego: full Lab 4 Rego with the three-way split of `no-matching-allow` |
| `06-verify.sh` | line 6770 | 4 narrative checks: ConfigMap has new reasons, last_successful_activation recent, missing-token request shows new reason header, log vocabulary covers new reasons |
| `07-break-it.sh` | line 6831 | Manual: patch opa-config to disable decision_logs.console; observe + repair stanza |
| `00-telemetry-loop-install.sh` | — | Orchestrator (mirrors Lab 6 pattern) |
| `verify.sh` | line 6803 | Umbrella pass/fail validation |

## Orchestrator behaviour

Mirrors Lab 6 structure exactly. `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab07)`.

### Step functions

1. `step_01_servicemonitor` — `kubectl apply` `01-opa-servicemonitor.yaml`, then `01-verify.sh`. (No rollout — Service + ServiceMonitor are immediate.)
2. `step_02_grafana_agent` — `kubectl apply` `02-grafana-agent.yaml`, `rollout status ds/grafana-agent --timeout=180s`, then `02-verify.sh`.
3. `step_03_istio_tracing` — `kubectl apply` `03-istio-tracing.yaml`, `rollout restart deploy/istiod`, `rollout status istiod`, then `03-verify.sh`.
4. `step_04_dashboard` — `kubectl apply` `04-dashboard.yaml`, sleep 15 s for the Grafana sidecar to pick up the ConfigMap, then `04-verify.sh`.
5. `step_05_load_mix` — runs `bash 05-load-mix.sh` (200 random requests), then `05-verify.sh`.
6. `step_06_refine_policy` — rebuilds the `pa-policies` ConfigMap from `06-zta.authz.rego` (NOT Lab 4's) using the same `--from-file=zta.authz.rego=...` pattern Lab 6 used, then `rollout restart deploy/pa` (PA rebuilds the signed bundle), `rollout status`, sleep 15 s for OPA to fetch the new bundle, then `06-verify.sh`.

After all steps: `echo "Lab 7 install completed successfully."`

## Special handling

### Refined Rego ships as a complete file

`06-zta.authz.rego` is the **full Lab 4 Rego with the catch-all line replaced** by three rules. The doc shows only the diff:

```
-decision := {"allow": false, "reason": "no-matching-allow"} if not allow
+decision := {"allow": false, "reason": "missing-token"}       if not token
+decision := {"allow": false, "reason": "invalid-subject"}     if { token; not claims.sub }
+decision := {"allow": false, "reason": "no-matching-allow"}   if { token; claims.sub; not allow }
```

We ship the full reconciled file. The orchestrator's step 06 rebuilds Lab 6's `pa-policies` ConfigMap from this refined file (overriding the build from Lab 4's `01-zta.authz.rego`).

### Port-forward cleanup pattern

Several verifies port-forward to Prometheus / Loki / Tempo / Grafana, curl, then `kill $PF_PID`. If the curl fails or the script aborts mid-way, the port-forward leaks. **Adaptation:** every port-forward block uses `trap 'kill $PF_PID 2>/dev/null' EXIT` (per-script trap). Per-step verify scripts already exit cleanly; the trap fires on any abort.

### Mesh ConfigMap clobber (step 03)

Same caveat as Lab 4: the doc's `03-istio-tracing.yaml` writes a complete `data.mesh` block. It explicitly lists BOTH `opa-ext-authz` (so Lab 4's wiring is preserved) and `otel-tempo` (the new addition). Server-side apply with `zta-lab07` field manager will rewrite the `mesh:` key as in Lab 4.

### `kube-prom` release name assumption

The ServiceMonitor's `release: kube-prom` label and the verify port-forwards (`svc/kube-prom-kube-prome-prometheus`, `svc/kube-prom-grafana`) assume the kube-prometheus-stack helm release is named `kube-prom`. This matches the doc. Bootstrap is assumed to have used this name. If not, scrape selection won't match and the Prometheus/Grafana port-forwards fail.

### OPA `/status` via `kubectl exec` in step 06 verify

The doc's step 06 verify uses `curl http://<clusterIP>:8282/status` from the host. Same Docker Desktop limitation as Lab 6 — switch to `kubectl exec deploy/opa -- wget -qO- http://localhost:8282/status`.

### State preservation

Lab 7 does not change the api pod's posture or the existing OPA bundle's signing key. After Lab 7, the api pod stays at `zta.posture=trusted` (set by Lab 6 step 5). The signed bundle now contains the refined Rego.

## Idempotency

- All `kubectl apply` calls use `--server-side --field-manager=zta-lab07`.
- Step 06 ConfigMap rebuild via `--from-file --dry-run | apply` is idempotent.
- Step 06 `rollout restart deploy/pa` is idempotent.
- Re-running the orchestrator regenerates dashboards and reapplies tracing config without harm.

## Out of scope

- Bootstrap (kube-prometheus-stack, Loki, Tempo, Grafana, Falco, Istio).
- Labs 1–6.
- Master install script (next session).
- Break-it cleanup is in-script (`07-break-it.sh` includes both the disable and the repair stanzas).

## Acceptance criteria

After running `00-telemetry-loop-install.sh` on a cluster with bootstrap + Labs 1–6 already applied:

1. The orchestrator completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. `kubectl -n zta-policy get svc opa-metrics` exists; `kubectl -n zta-observability get servicemonitor opa` carries `release=kube-prom`.
4. `kubectl -n zta-observability get ds grafana-agent` is fully ready.
5. `kubectl -n istio-system get telemetry mesh-default` reports `otel-tempo/100`.
6. `kubectl -n zta-observability get cm zta-dashboard` carries `grafana_dashboard=1` and the embedded JSON has exactly 4 panels.
7. After step 5: Loki has decision events for trusted, suspect, and tampered postures within the last 10 minutes.
8. After step 6: OPA's recent decision log includes `reason: missing-token` for an unauthenticated request and the `pa-policies` ConfigMap contains the new reason strings.
9. Re-running the orchestrator on the same cluster does not error out.

## File-by-file source mapping

YAML files are **verbatim** from `index.html` `<pre><code>` blocks (HTML entities decoded). Bash scripts are verbatim with these specific edits:

- `05-load-mix.sh` and `06-verify.sh`: `source labs/03-per-session/.env` becomes `source "$SCRIPT_DIR/../03-per-session/.env"`.
- `06-verify.sh`: `curl http://<clusterIP>:8282/status` becomes `kubectl exec deploy/opa -- wget -qO- http://localhost:8282/status`.
- All verifies that port-forward gain a `trap 'kill $PF_PID 2>/dev/null' EXIT`.
- `06-zta.authz.rego`: full Lab 4 Rego with the catch-all line replaced by the three rules from the doc's diff (verbatim within those three lines).

Per-step verify scripts follow the narrative pattern (no shebang, no `set -e`, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script using the `check` helper.

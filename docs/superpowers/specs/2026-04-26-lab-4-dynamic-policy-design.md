# Lab 4 — Dynamic Policy — Design

**Date:** 2026-04-26
**Scope:** Lab 4 only (`files/zta-homelab/labs/04-dynamic-policy/`). Labs 5–7 and the master install script are out of scope.
**Pattern source:** Labs 1–3 (most-recent applied: Lab 3).
**Snippet source:** `index.html` lines 4328–4953.

## Goal

Convert Lab 4's code snippets in `index.html` into runnable scripts and manifests that follow the established pattern.

After running `00-dynamic-policy-install.sh`, the cluster has:
- A Rego policy `zta.authz` mounted into the bootstrap-installed OPA Deployment in `zta-policy`.
- The OPA Deployment running with `envoy_ext_authz_grpc` plugin and `decision_logs.console=true`.
- An `opa-ext-authz` extension provider registered at the mesh root.
- An `EnvoyFilter` adding the `opa-ext-authz` cluster on inbound sidecars + a `CUSTOM` `AuthorizationPolicy` on the `bookstore-api` selecting the provider.
- A driven request matrix proving the policy: `trusted/GET=200`, `trusted/POST=200`, `suspect/GET=200`, `suspect/POST=403`, `tampered/GET=403`, `tampered/POST=403`.
- OPA decision logs containing one `decision_id`-bearing JSON line per request.

## Files to create

All files live in `files/zta-homelab/labs/04-dynamic-policy/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `01-zta.authz.rego` | line 4504 | Rego policy file, verbatim |
| `01-verify.sh` | line 4591 | 3 narrative checks: `opa parse`, default-deny grep, two `opa eval` calls (trusted-GET=true, tampered=device-tampered) |
| `02-opa-deployment.yaml` | line 4624 | Deployment patch — adds args (ext_authz, decision logs), volume mount `/policies`. ConfigMap is built dynamically from `01-zta.authz.rego` at install time. |
| `02-verify.sh` | line 4660 | 4 narrative checks: ConfigMap contains package, OPA args contain new flags, OPA REST `/v1/policies` lists the policy, default-deny query returns `false / default-deny` |
| `03-ext-authz-provider.yaml` | line 4737 | Mesh-root `istio` configmap with `extensionProviders` |
| `03-ext-authz-envoyfilter.yaml` | line 4694 | `EnvoyFilter` (cluster `opa-ext-authz`) + `AuthorizationPolicy` (CUSTOM/opa-ext-authz on `app=api`) |
| `03-verify.sh` | line 4765 | 5 narrative checks: provider in mesh config, EnvoyFilter present, AuthorizationPolicy CUSTOM/opa-ext-authz, ext_authz filter on listener, OPA gRPC reachable from sidecar |
| `04-three-requests.sh` | line 4799 | Drives the 3-posture × 2-method matrix; sources `../03-per-session/.env` |
| `04-verify.sh` | line 4831 | 3 narrative checks: capture matrix into `/tmp/zta-matrix.txt`, exact 6-row decision shape, denied response carries `x-zta-decision-id` header |
| `05-verify.sh` | line 4879 | 4 narrative checks: ≥6 decision lines, 6 unique decision_ids, reasons cover ok/device-tampered/no-matching-allow, every decision has method/posture/principal |
| `06-break-it.sh` | line 4927 | Manual exercise (NOT run by install): change `else := "unknown"` to `else := "trusted"`, redeploy OPA, attack with no posture header |
| `00-dynamic-policy-install.sh` | — | Orchestrator with pauses; mirrors Lab 1/2/3 pattern |
| `verify.sh` | line 4908 | Umbrella pass/fail validation |

## Orchestrator behaviour

Mirrors the Lab 3 orchestrator structure exactly. `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab04)`.

### Step functions

1. `step_01_rego_policy` — runs `01-verify.sh` (which expects the local `01-zta.authz.rego` file already on disk, parses it with the local `opa` CLI). No cluster work.
2. `step_02_load_policy` — builds the ConfigMap from disk: `kubectl create configmap opa-policy --from-file=zta.authz.rego=01-zta.authz.rego -n zta-policy --dry-run=client -o yaml | kubectl apply --server-side --field-manager=zta-lab04 -f -`. Then `kubectl apply` the Deployment patch. Then `kubectl rollout status deploy/opa -n zta-policy --timeout=120s`. Then `02-verify.sh`.
3. `step_03_wire_envoy` — `kubectl apply` the provider, `kubectl apply` the envoyfilter, `rollout restart deploy/istiod`, `rollout status istiod`, `rollout restart deploy/api -n bookstore-api`, `rollout status api`. Then `03-verify.sh`.
4. `step_04_three_requests` — sources `../03-per-session/.env` (so `BOOKSTORE_CLIENT_SECRET` is in scope), runs `04-three-requests.sh` to display the matrix, then runs `04-verify.sh` to capture it into `/tmp/zta-matrix.txt` and assert.
5. `step_05_decision_log` — runs `05-verify.sh`. Pure log inspection; the OPA logs already contain decisions from step 4's matrix.

After all steps: `echo "Lab 4 install completed successfully."`

## Special handling

### `opa` CLI prerequisite (step 01)

`01-verify.sh` runs `opa parse` and `opa eval` locally — same as the doc. This adds `opa` (v1.0+) to Lab 4's prerequisites. If `opa` is not installed, step 01 verify prints the binary-not-found error and the orchestrator aborts. The umbrella `verify.sh` does NOT use local `opa` — it queries the running OPA pod via `kubectl exec`, so the umbrella is runnable without local opa.

### istio mesh-root configmap (step 03)

The doc's `03-ext-authz-provider.yaml` is a full `ConfigMap` named `istio` in `istio-system`. `kubectl apply` of this would replace any other `mesh:` keys bootstrap may have populated. Behaviour:

- **Assumption (matches the doc verbatim):** bootstrap leaves the `istio-system/istio` configmap with only the `mesh` key, or merging with the doc's content via server-side apply yields a usable mesh config.
- **Risk noted:** if bootstrap put e.g. `meshNetworks` or other top-level keys in this configmap, server-side apply with field manager `zta-lab04` will not delete them, but the `mesh` key itself will be rewritten — anything previously in `mesh:` is lost.
- The verify (`03-verify.sh` check #1) confirms `extensionProviders` contains `opa-ext-authz`. If bootstrap had other `extensionProviders`, they're gone.
- A `kubectl patch --type=merge` against `data.mesh` would be safer; this design matches the doc rather than improving on it. A future task could swap in `kubectl patch` if integration testing reveals a clobber problem.

### Lab 3 dependency (step 04 + break-it)

`04-three-requests.sh`, `04-verify.sh`, and `06-break-it.sh` all source `"$SCRIPT_DIR/../03-per-session/.env"` to acquire `BOOKSTORE_CLIENT_SECRET`. If Lab 3 hasn't run, `.env` is absent and these scripts abort cleanly with a "missing .env — run Lab 3 first" error.

### `$TOKEN` reuse pattern (consistent with Lab 3)

`04-verify.sh` and `05-verify.sh` (anywhere they need a token) check `[ -z "${TOKEN:-}" ]` and re-acquire from `.env` if unset, so they're runnable standalone.

### istiod and api restarts (step 03)

The doc explicitly restarts both `istiod` (so the mesh config reload picks up the extension provider) and the api pod (so its sidecar applies the CUSTOM authorization). The orchestrator runs both and waits for rollout. Total step-03 duration: ~30–90 s of cluster churn.

## Idempotency

- ConfigMap build via `--from-file ... --dry-run=client | kubectl apply -f -` is fully idempotent.
- All `kubectl apply` calls use `--server-side --field-manager=zta-lab04`.
- `rollout restart` is idempotent (creates a new revision; if the spec hasn't changed, the new revision is a no-op).
- The OPA Deployment patch is server-side merged — re-runs do not duplicate args because they're matched by position+content.

## Out of scope

- Bootstrap (assumed to have created the OPA Deployment in `zta-policy`, the bookstore api, and Keycloak).
- Lab 3 (provides `.env` with Keycloak credentials).
- Local `opa` CLI installation (documented prerequisite).
- Master install across all 7 labs (separate session).
- Break-it cleanup (manual; the doc says "Repair: restore the default to 'unknown' and redeploy").

## Acceptance criteria

After running `00-dynamic-policy-install.sh` on a cluster with bootstrap + Labs 1–3 already applied:

1. The orchestrator completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. The 6-row matrix in `/tmp/zta-matrix.txt` exactly matches: `trusted GET 200`, `trusted POST 200`, `suspect GET 200`, `suspect POST 403`, `tampered GET 403`, `tampered POST 403`.
4. `kubectl logs -n zta-policy deploy/opa --tail=200 | jq 'select(.decision_id != null)' | wc -l` ≥ 6.
5. Each decision in the OPA log has `input.attributes.request.http.method`, `input.attributes.request.http.headers["x-device-posture"]`, and `input.attributes.source.principal` set.
6. Re-running the orchestrator on the same cluster does not error out.

## File-by-file source mapping

YAML files are **verbatim** from `index.html` `<pre><code>` blocks (HTML entities decoded). The Rego file is verbatim from line 4504.

Two specific edits from the doc:
- `02-opa-deployment.yaml` is the ConfigMap-elided portion of the doc's `02-opa-policy.yaml` — only the Deployment patch. The ConfigMap is built at install time from the on-disk Rego.
- `04-three-requests.sh` and `06-break-it.sh`: `source labs/03-per-session/.env` is rewritten to `source "$SCRIPT_DIR/../03-per-session/.env"` so paths resolve from the lab dir.

Per-step verify scripts follow Lab 1–3's narrative pattern (no `set -e`, no shebang, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script using the `check` helper.

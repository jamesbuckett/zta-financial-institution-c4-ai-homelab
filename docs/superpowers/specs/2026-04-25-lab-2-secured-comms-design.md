# Lab 2 — Secured Comms — Design

**Date:** 2026-04-25
**Scope:** Lab 2 only (`files/zta-homelab/labs/02-secured-comms/`). Labs 3–7 and the master install script are explicitly out of scope and will land in follow-on sessions.
**Pattern source:** Lab 1 (`files/zta-homelab/labs/01-resources/`).
**Snippet source:** `index.html` lines 3326–3799.

## Goal

Convert the Lab 2 code snippets in `index.html` into runnable scripts and manifests that match the structure already established in Lab 1: numeric-prefixed step files, a per-step verify script, an orchestrator (`00-secured-comms-install.sh`) that runs each step with a pause, and an umbrella `verify.sh` for end-to-end validation.

The output of running `00-secured-comms-install.sh` must be an Istio mesh with mesh-wide `STRICT` mTLS, default-deny `AuthorizationPolicy` in `bookstore-api` and `bookstore-data`, an out-of-mesh `debug` pod that fails to reach the api, and a `/tmp/capture.txt` containing TLS-encrypted traffic between the frontend and api sidecars.

## Files to create

All files live in `files/zta-homelab/labs/02-secured-comms/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `01-peer-authn-strict.yaml` | line 3449 | Mesh-wide STRICT `PeerAuthentication` in `istio-system` |
| `01-verify.sh` | line 3469 | 3 checks: mode=STRICT, no namespace override, sidecar inbound listener has TLS transport socket |
| `02-default-deny.yaml` | line 3493 | 4 `AuthorizationPolicy` resources: deny-all in api+data, allow ingress→frontend, allow ingress+frontend→api |
| `02-verify.sh` | line 3537 | 3 checks: empty-spec deny in api+data, allow principals correct, RBAC filter wired in Envoy |
| `03-debug-pod.yaml` | line 3568 | `zta-lab-debug` namespace with `istio-injection: disabled` + netshoot pod with `NET_RAW`/`NET_ADMIN` |
| `03-verify.sh` | line 3599 | 3 checks: ns label, exactly one container (no sidecar), tcpdump+caps present |
| `04-verify.sh` | line 3636 | 3 checks: curl exits 52 (Empty reply), `nc` returns no HTTP response, access log shows `connection_termination_details` |
| `05-verify.sh` | line 3684 | 4 checks: capture non-empty, no plaintext HTTP, TLS records present, port 15006 visible |
| `06-verify.sh` | line 3719 | 4 checks: `istioctl tls-check` reports `OK STRICT ISTIO_MUTUAL`, SVID secrets present, SAN URI = `spiffe://cluster.local/ns/bookstore-api/sa/default`, capture/control-plane agree |
| `06-break-it.yaml` | line 3774 | Downgrade `PeerAuthentication` for the manual break-it exercise (NOT run by install) |
| `00-secured-comms-install.sh` | — (orchestrator) | Runs steps 01–06 with `clear`+pause between each; mirrors `00-resources-install.sh` line-for-line |
| `verify.sh` | line 3750 | Umbrella validation block from the doc; consolidated read-only assertions |

## Orchestrator behaviour

`00-secured-comms-install.sh` follows Lab 1's `00-resources-install.sh` exactly:

- `set -euo pipefail`
- `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab02)`
- `cd` to script dir
- `on_error` trap that prints which step failed
- `pause` reads Enter between steps
- `run_step "<label>" <function>` clears, prints banner, runs, pauses
- One function per step; each function applies the YAML (or runs the bash snippet) then `bash NN-verify.sh`

Step functions:

1. `step_01_peer_authn_strict` — `kubectl apply` `01-peer-authn-strict.yaml`, then `01-verify.sh`
2. `step_02_default_deny` — `kubectl apply` `02-default-deny.yaml`, then `02-verify.sh`
3. `step_03_debug_pod` — `kubectl apply` `03-debug-pod.yaml`, then `kubectl wait --for=condition=Ready pod/debug --timeout=60s`, then `03-verify.sh`
4. `step_04_plaintext_attempt` — runs the curl. **Designed failure**: curl is expected to exit non-zero (52). Wrapped so non-zero is success and exit 0 is the abort condition. Then `04-verify.sh`.
5. `step_05_packet_capture` — see "Step 05 special handling" below
6. `step_06_istio_cross_check` — runs `istioctl authn tls-check`, then `06-verify.sh`

After all steps: `echo "Lab 2 install completed successfully."`

## Step 04 special handling (designed failure)

The curl in Step 04 is *expected* to fail with exit code 52 (Empty reply). The orchestrator must:

- Run the curl under a wrapper that captures the exit code
- Treat exit 52 (or any non-zero) as success
- Treat exit 0 as failure (mTLS is broken — abort with a clear message)

Pattern:

```bash
set +e
kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
    curl -sS --max-time 5 http://api.bookstore-api.svc.cluster.local/headers
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: plaintext call unexpectedly succeeded — STRICT mTLS not enforced"
    exit 1
fi
echo "OK: plaintext call refused (exit=$rc)"
```

## Step 05 special handling (concurrent capture + traffic)

The doc shows two terminals. The orchestrator collapses them into one script:

1. `rm -f /tmp/capture.txt`
2. Background `kubectl exec debug -- tcpdump -i any -nn -s 0 -c 30 -A 'tcp port 80 or tcp port 15006'` redirected to `/tmp/capture.txt`. Capture PID.
3. `sleep 2` — give tcpdump time to attach.
4. Loop: 10× `kubectl exec frontend -c nginx -- wget -qO- http://api.bookstore-api.svc.cluster.local/headers >/dev/null`, with `sleep 0.3` between calls.
5. `wait $TCPDUMP_PID` — `-c 30` makes tcpdump auto-terminate. If it has not exited 15 seconds after the last wget, `kill $TCPDUMP_PID` and continue; `05-verify.sh` will report failure if the capture is empty.
6. Run `05-verify.sh`.

`/tmp/capture.txt` is host-side (the pipe is in the kubectl exec wrapper, not inside the pod). Step 06's verify also reads it for the "capture and control-plane agree" check.

## Idempotency

- All `kubectl apply` calls use `--server-side --field-manager=zta-lab02` (Lab 1 pattern).
- `03-debug-pod.yaml` defines a `Pod` (not a Deployment). Server-side apply re-runs cleanly when the spec is unchanged. If a learner edits the pod spec and re-runs, server-side apply will surface a conflict — that's the same behaviour Lab 1 has and is intentional.
- The break-it `PeerAuthentication` (`06-break-it.yaml`) is never applied by install. The learner runs it manually, then deletes it.

## Out of scope

- **Bookstore workloads** (`frontend`, `api`, `db`) are assumed present from bootstrap (`index.html` §2.6). Lab 2 does not create or modify them. If absent, step 05's traffic-driving wget will fail — verify will catch it and the orchestrator will abort.
- **Master install.sh** (`files/zta-homelab/install.sh` or similar) covering all 7 labs is **not** part of this design. It will land in a follow-on session once labs 3–7 exist.
- **Lab 2's break-it cleanup** is the learner's responsibility (the doc says "Restore: kubectl delete peerauthentication downgrade" — left manual, mirroring Lab 1's `05-break-it.yaml`).
- **Re-running install across labs**: nothing in this design coordinates ordering with other labs. Lab 2 assumes Lab 1 has already run (workloads exist with ZTA labels). It does not assume Lab 3+ state.

## Acceptance criteria

After running `00-secured-comms-install.sh` on a clean Docker Desktop with bootstrap + Lab 1 already applied:

1. The script completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. `kubectl -n istio-system get peerauthentication default -o jsonpath='{.spec.mtls.mode}'` returns `STRICT`.
4. `kubectl -n zta-lab-debug exec debug -- curl -sS --max-time 3 http://api.bookstore-api.svc.cluster.local/headers; echo $?` prints curl error and exit `52`.
5. A frontend→api wget succeeds and the response includes an `X-Forwarded-Client-Cert` header containing `By=spiffe://cluster.local/...`.
6. Re-running the install on the same cluster does not error out (idempotent under server-side apply).

## File-by-file source mapping

For the implementation plan, the YAML files are **verbatim** copies of the index.html `<pre><code>` blocks (HTML entities decoded: `&lt;`→`<`, `&gt;`→`>`, `&amp;`→`&`).

Per-step verify scripts (`01-verify.sh` … `06-verify.sh`) follow Lab 1's narrative pattern: each numbered check prints a heading via `printf`, runs the kubectl/istioctl command verbatim from the doc, and is followed by an `# Expected: ...` comment. They do not use the `check` helper and do not have `set -e` — they exist for the learner to read inline as the orchestrator pauses between steps.

The umbrella `verify.sh` is the strict pass/fail script. It wraps every assertion with the `check "<label>" <command>` helper from Lab 1's `verify.sh` so failures print a `FAIL <label>` line and the overall script exits non-zero on the first failed step.

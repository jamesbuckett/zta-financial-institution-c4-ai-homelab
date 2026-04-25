# Master install.sh — Design

**Date:** 2026-04-26
**Scope:** A single end-to-end installer that runs bootstrap + Labs 1–7 in order, with non-interactive pauses, on a clean Docker Desktop cluster.

## Goal

Provide a single command that, on a fresh `docker-desktop` Kubernetes cluster, installs the entire ZTA homelab in one shot, runs each lab's umbrella verify, and aborts cleanly on the first failure.

After running `files/zta-homelab/install.sh`:

- Bootstrap is applied (namespaces, cert-manager, Istio, SPIRE, Keycloak, OPA, Gatekeeper, Falco, observability, bookstore).
- Labs 1–7 are applied in order; each lab's umbrella `verify.sh` passes.
- Final exit code is 0 and a "All seven labs installed and verified" message prints.
- On any failure, the script aborts at the failing step and prints which lab/verify aborted.

## Files to modify

Eight existing orchestrator scripts gain a `ZTA_NO_PAUSE` opt-out in their `pause()` function. The change is identical in every file:

```bash
pause() {
    if [ "${ZTA_NO_PAUSE:-0}" = "1" ]; then
        return 0
    fi
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}
```

The orchestrators receiving this patch:
- `files/zta-homelab/bootstrap/00-bootstrap-install.sh`
- `files/zta-homelab/labs/01-resources/00-resources-install.sh`
- `files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh`
- `files/zta-homelab/labs/03-per-session/00-per-session-install.sh`
- `files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh`
- `files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh`
- `files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh`
- `files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh`

## File to create

`files/zta-homelab/install.sh` — the master installer.

## Master install.sh behaviour

`set -euo pipefail`. Cluster context `docker-desktop`. By default exports `ZTA_NO_PAUSE=1` so the chained orchestrators run unattended.

### CLI

```
Usage: ./install.sh [options]

Options:
  --pause              Keep the per-step pauses inside each lab (interactive).
  --skip-bootstrap     Assume bootstrap is already applied; skip it.
  --from N             Start at lab N (1-7). Skips bootstrap and labs < N.
  --verify-only        Run each lab's umbrella verify.sh; do NOT install.
  --help, -h           Print this help.
```

### Flow (default invocation)

1. Print banner with options in effect.
2. If not `--skip-bootstrap` and not `--from N`: run `bootstrap/00-bootstrap-install.sh`. (Bootstrap has no umbrella verify; the orchestrator's own `set -e` aborts on failure.)
3. For each lab `N` from `${FROM:-1}` to `7`:
   - If `--verify-only`: run `bash labs/0N-<name>/verify.sh` only.
   - Else: run `bash labs/0N-<name>/00-<name>-install.sh`, then `bash labs/0N-<name>/verify.sh`. Abort on either failure.
4. Print "All seven labs installed and verified" and exit 0.

### Lab name mapping

```bash
LABS=(
  "01-resources:00-resources-install.sh"
  "02-secured-comms:00-secured-comms-install.sh"
  "03-per-session:00-per-session-install.sh"
  "04-dynamic-policy:00-dynamic-policy-install.sh"
  "05-posture-monitoring:00-posture-monitoring-install.sh"
  "06-strict-enforcement:00-strict-enforcement-install.sh"
  "07-telemetry-loop:00-telemetry-loop-install.sh"
)
```

### Error handling

The master uses `set -euo pipefail` plus a `trap` that prints a clear "FAILED at <stage>" message before exiting. It does NOT swallow errors — first failure halts everything.

### Idempotency

All eight orchestrators are individually idempotent (server-side apply, `--from-file --dry-run | apply`, "already exists" tolerance). The master just chains them, so re-running the master against an already-installed cluster is a no-op (modulo time spent waiting for `rollout status`).

## Out of scope

- A "teardown" / uninstall path. Each lab has a manual break-it; cluster cleanup is `kubectl delete ns ...` per the bootstrap namespaces.
- Parallel lab execution. Labs are strictly sequential because Lab N+1 reads state Lab N produced.
- Non-Docker-Desktop targets. The cluster context is hardcoded to `docker-desktop` in every orchestrator.
- Logging / `tee`. The user can `2>&1 | tee install.log` if they want a transcript.

## Acceptance criteria

1. `./files/zta-homelab/install.sh --help` prints the usage block.
2. `./files/zta-homelab/install.sh` on a clean cluster:
   - Runs bootstrap to completion (no pauses).
   - Runs each of Labs 1–7 with no pauses; each lab's umbrella `verify.sh` passes.
   - Final exit code 0; final message "All seven labs installed and verified".
3. `./files/zta-homelab/install.sh --skip-bootstrap` on a cluster with bootstrap already applied: produces the same end state without re-running bootstrap.
4. `./files/zta-homelab/install.sh --from 5` runs only Labs 5, 6, 7 (and their verifies).
5. `./files/zta-homelab/install.sh --verify-only` runs only the seven `verify.sh` umbrellas; does not modify cluster state.
6. `./files/zta-homelab/install.sh --pause` re-enables the per-step pauses inside each orchestrator (each lab walks through its steps interactively).
7. Re-running the master twice in a row succeeds both times (idempotency).
8. Each individual orchestrator, run standalone (without `ZTA_NO_PAUSE`), still pauses between steps as before — the patch is opt-in.

## File-by-file changes

### Pause patch (eight files, identical)

Replace:
```bash
pause() {
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}
```
with:
```bash
pause() {
    if [ "${ZTA_NO_PAUSE:-0}" = "1" ]; then
        return 0
    fi
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}
```

### `files/zta-homelab/install.sh` (new)

See the implementation plan for the full content. Key points:
- `set -euo pipefail`, `KCTX="docker-desktop"`, `SCRIPT_DIR` resolution.
- Argument parser using a simple `case` block.
- A `LABS` array as above.
- A trap that prints `FAILED at <stage>` and exits with the original code.
- `chmod +x` so it can be invoked directly (`./install.sh`).

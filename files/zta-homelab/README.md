# `install.sh` — ZTA homelab master installer

End-to-end installer for the seven NIST SP 800-207 lab modules on a local
Docker Desktop Kubernetes cluster. Runs the bootstrap, then each lab's
install + umbrella verify in order. Aborts on the first failed step, so a
green run is a real green run.

## Quick start

```bash
cd files/zta-homelab
./install.sh                       # full end-to-end install, no pauses
```

Re-running against an already-installed cluster is a no-op (modulo
rollout-status waits) — every step uses server-side apply or
`helm upgrade --install`.

## Usage

```
./install.sh [--pause] [--skip-bootstrap] [--from N] [--verify-only] [--help]
```

| Option | Meaning |
| --- | --- |
| `--pause` | Keep the per-step pauses inside each lab orchestrator (interactive). Default is non-interactive. |
| `--skip-bootstrap` | Assume bootstrap is already applied; skip it. |
| `--from N` | Start at lab `N` (1–7). Skips bootstrap and labs `< N`. |
| `--verify-only` | Run each lab's umbrella `verify.sh`; do not install. |
| `--help`, `-h` | Print help and exit. |

Exit codes: `0` success, `1` step or verify failed, `2` bad CLI argument.

## Common scenarios

```bash
./install.sh --pause               # full install, with per-step pauses
./install.sh --skip-bootstrap      # bootstrap already done; install labs only
./install.sh --from 5              # install labs 5, 6, 7 only
./install.sh --verify-only         # check the cluster matches the lab specs
./install.sh --from 5 --pause      # combine flags freely
```

## Labs

| # | Directory | NIST 800-207 tenet |
| - | --- | --- |
| 1 | `labs/01-resources`          | T1 — All data sources and computing services are resources |
| 2 | `labs/02-secured-comms`      | T2 — All communication is secured regardless of network location |
| 3 | `labs/03-per-session`        | T3 — Access is granted on a per-session basis |
| 4 | `labs/04-dynamic-policy`     | T4 — Access is determined by dynamic policy |
| 5 | `labs/05-posture-monitoring` | T5 — Monitor and measure integrity/security posture of all assets |
| 6 | `labs/06-strict-enforcement` | T6 — Authentication and authorization are strictly enforced |
| 7 | `labs/07-telemetry-loop`     | T7 — Collect telemetry and use it to improve security posture |

## Prerequisites

- **Docker Desktop** with Kubernetes enabled (single-node). Suggested 6 CPU / 8 GB RAM.
- **kubectl** context `docker-desktop` (the installer hard-codes this).
- **helm 3+** on `PATH` with the `falcosecurity` repo added (Lab 5):
  ```bash
  helm repo add falcosecurity https://falcosecurity.github.io/charts
  helm repo update
  ```
- **opa CLI** v1.0+ on `PATH` (used by Lab 4's `01-verify.sh`).
- Standard tools: `jq`, `yq`, `awk`, `sed`, `curl`, `openssl`.
- `/etc/hosts` entries that route `bookstore.local` and `keycloak.local`
  to `127.0.0.1` (added by bootstrap).

## When it fails

The trap prints the failing stage and exits non-zero, e.g.:

```
===============================================================
MASTER INSTALL FAILED at stage: lab 5 verify (05-posture-monitoring) (exit 1)
Fix the issue above, then re-run ./install.sh.
===============================================================
```

Fix the underlying issue, then re-run — `./install.sh` is idempotent and
will skip already-applied state. To resume from a specific lab without
redoing the earlier ones, use `./install.sh --from N`.

If a lab fails specifically because Lab 3's `.env` has drifted from
Keycloak's stored `bookstore-api` client secret (e.g., Keycloak was
restarted out-of-band), the verifies in Labs 5/6/7 self-heal it via
`labs/03-per-session/refresh-env.sh`. You can also run that helper by
hand.

## Related scripts

- `bootstrap/00-bootstrap-install.sh` — cluster-wide prerequisites
  (cert-manager, Istio, Keycloak, SPIRE, sample app, …). Invoked by
  `install.sh` unless `--skip-bootstrap`.
- `labs/<NN>/verify.sh` — per-lab umbrella verify. Run any one in
  isolation to spot-check a single tenet.
- `labs/<NN>/00-*-install.sh` — per-lab orchestrator. Drives each step
  manifest and per-step verify; pauses between steps unless
  `ZTA_NO_PAUSE=1`.
- `labs/03-per-session/refresh-env.sh` — re-derives
  `BOOKSTORE_CLIENT_SECRET` from Keycloak into `.env`. Idempotent;
  silent no-op if Keycloak isn't reachable.
- `teardown.sh` — uninstall everything.

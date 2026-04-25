# Lab 3 — Per-Session — Design

**Date:** 2026-04-26
**Scope:** Lab 3 only (`files/zta-homelab/labs/03-per-session/`). Labs 4–7 and the master install script are out of scope.
**Pattern source:** Lab 1 (orchestrator + umbrella verify) and Lab 2 (most-recent applied pattern).
**Snippet source:** `index.html` lines 3807–4319.

## Goal

Convert Lab 3's code snippets in `index.html` into runnable scripts and manifests that follow the established pattern: numeric-prefixed step files, per-step narrative verify scripts, an orchestrator (`00-per-session-install.sh`) with pauses, and an umbrella `verify.sh`.

After running `00-per-session-install.sh`, the cluster has:
- A Keycloak realm `zta-bookstore` with 5-minute access tokens, a confidential client `bookstore-api`, and a test user `alice/alice`.
- A SPIRE registration entry `spiffe://zta.homelab/ns/bookstore-api/sa/default` with `x509SVIDTTL=300` and `jwtSVIDTTL=300`.
- A `svid-watcher` Deployment in `bookstore-api` running `spiffe-helper` + an `observer` container that prints SVID serial/notAfter every 15 s.
- At least one observed SVID rotation in the observer logs (because rotation happens at TTL/2 ≈ 150 s and the orchestrator waits 180 s).

## Files to create

All files live in `files/zta-homelab/labs/03-per-session/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `.gitignore` | — | Excludes `.env` (contains Keycloak client secret) |
| `01-keycloak-realm.sh` | line 3937 | Bash script: create realm, client, user via `kcadm.sh`; write `.env` |
| `01-verify.sh` | line 3970 | 4 narrative checks: realm OIDC config, `accessTokenLifespan=300`, client+user present, `.env` written |
| `02-token-and-expiry.sh` | line 4004 | Bash: source `.env`, OAuth2 password grant, decode JWT exp/iat. Sets and exports `TOKEN`. |
| `02-verify.sh` | line 4031 | 4 narrative checks: 3 JWT segments, `alg≠none`, lifetime=300, JWKS published |
| `03-spire-register.sh` | line 4063 | Bash: `spire-server entry create` for bookstore-api workload, TTL 300 |
| `03-verify.sh` | line 4085 | 4 narrative checks: entry exists, TTL=300, agent registered, no duplicates |
| `04-svid-watcher.yaml` | line 4119 | Deployment (helper + observer) + `svid-helper` ConfigMap |
| `04-verify.sh` | line 4177 | 4 narrative checks: 1/1 ready, watcher+observer containers, ConfigMap mounted, `/svid/svid.pem` appears |
| `05-verify.sh` | line 4222 | 4 narrative checks: ≥2 distinct serials in 180 s, URI SAN matches, notAfter ≤5 min, token TTL = SVID TTL |
| `06-break-it.sh` | line 4274 | Manual exercise (NOT run by install): replay expired token through Istio JWT validation |
| `00-per-session-install.sh` | — | Orchestrator with pauses; mirrors Lab 1/2 pattern |
| `verify.sh` | line 4248 | Umbrella pass/fail validation; mirrors Lab 1/2 pattern |

## Orchestrator behaviour

Mirrors `00-resources-install.sh` and `00-secured-comms-install.sh` exactly:

- `set -euo pipefail`, `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab03)`
- Same `on_error`/`pause`/`run_step` helpers
- Function per step

### Step functions

1. `step_01_keycloak_realm` — runs `bash 01-keycloak-realm.sh`, then `01-verify.sh`. Writes `.env` to the script's directory.
2. `step_02_token_and_expiry` — sources `.env`, runs `02-token-and-expiry.sh` which exports `TOKEN`, then `02-verify.sh`. The orchestrator keeps `TOKEN` in scope for later step functions that need it (step 5 verify).
3. `step_03_spire_register` — runs `bash 03-spire-register.sh`, then `03-verify.sh`. Tolerant of "entry already exists" on re-run (capture stderr, ignore `already exists`).
4. `step_04_svid_watcher` — `kubectl apply --server-side` `04-svid-watcher.yaml`, `kubectl rollout status` 120 s, `04-verify.sh`.
5. `step_05_watch_rotation` — prints "Waiting 180 s for SVID rotation…", `sleep 180`, `05-verify.sh`. The orchestrator already has `TOKEN` exported (from step 2's function); `05-verify.sh` re-acquires it from `.env` if not present (so it's runnable standalone).

After all steps: `echo "Lab 3 install completed successfully."`

## State sharing — `.env` and `$TOKEN`

**`.env`** is created by step 1 in the same directory as the script, via `"$(dirname "${BASH_SOURCE[0]}")/.env"`. The doc-source path `labs/03-per-session/.env` is rewritten to that pattern so `01-keycloak-realm.sh` works from any cwd.

**`.gitignore`** in the lab directory contains `.env` (single line). The file is otherwise valid bash that any verify script can `source`.

**`$TOKEN`** is set by `02-token-and-expiry.sh`. The orchestrator runs it via `source` (or via `bash -c` while exporting), so subsequent step functions in the same orchestrator process inherit `TOKEN`. **Independence rule:** every verify script that needs `$TOKEN` (currently `02-verify.sh` and `05-verify.sh`) will check `[ -z "${TOKEN:-}" ]` and re-acquire from `.env` if unset — so they run standalone without the orchestrator.

## Idempotency

- `kubectl apply --server-side --field-manager=zta-lab03` for `04-svid-watcher.yaml` (idempotent).
- `01-keycloak-realm.sh`: `kcadm.sh create realms`, `create clients`, `create users` all fail if the resource already exists. The script will be wrapped to ignore "already exists" errors and continue (the verify confirms post-state, regardless of whether this run created or found the resources).
- `03-spire-register.sh`: `spire-server entry create` returns "entry already exists" on re-run. Same approach — ignore that specific error and let the verify confirm.

## Out of scope

- Bookstore workloads (frontend/api/db) — assumed present from bootstrap and Lab 1.
- Keycloak deployment itself — assumed running in `zta-identity` namespace from bootstrap §2.6.
- SPIRE server/agent — assumed running in `spire` namespace from bootstrap §2.5.
- Master install across all 7 labs — separate session.
- Break-it cleanup — manual (the doc's break-it leaves a `RequestAuthentication` and `AuthorizationPolicy` behind that the learner restores).

## Acceptance criteria

After running `00-per-session-install.sh` on a clean cluster with bootstrap + Lab 1 + Lab 2 already applied:

1. The orchestrator completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. `kubectl -n zta-identity exec <kc-pod> -- /opt/keycloak/bin/kcadm.sh get realms/zta-bookstore --fields accessTokenLifespan` reports `300`.
4. `kubectl -n spire exec <spire-server> -- /opt/spire/bin/spire-server entry show -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default | grep 'X509-SVID TTL'` reports `300`.
5. The `svid-watcher` deployment is `1/1 Available` and the observer container has logged at least two distinct SVID serials within the last 180 s.
6. Re-running the orchestrator on the same cluster does not error out.

## File-by-file source mapping

YAML files are **verbatim** copies of `index.html` `<pre><code>` blocks (HTML entities decoded). Bash scripts are verbatim with two specific edits:

- `01-keycloak-realm.sh`: the doc's `> labs/03-per-session/.env` is rewritten to `> "$(dirname "${BASH_SOURCE[0]}")/.env"` so it resolves correctly when invoked from the lab directory.
- `01-keycloak-realm.sh` and `03-spire-register.sh`: each `kc create` / `entry create` is wrapped to tolerate "already exists" on re-run (`|| true` is too broad; will pattern-match the specific error string instead).

Per-step verify scripts follow Lab 1/2's narrative pattern (no `set -e`, no shebang, but `chmod +x` for consistency with Lab 1).

The umbrella `verify.sh` is the strict pass/fail script using the `check` helper from Lab 1/2.

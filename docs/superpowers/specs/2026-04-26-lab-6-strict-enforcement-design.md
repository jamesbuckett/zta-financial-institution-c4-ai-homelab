# Lab 6 — Strict Enforcement — Design

**Date:** 2026-04-26
**Scope:** Lab 6 only (`files/zta-homelab/labs/06-strict-enforcement/`). Lab 7 and the master install script are out of scope.
**Pattern source:** Labs 1–5.
**Snippet source:** `index.html` lines 5568–6196.

## Goal

Convert Lab 6's snippets into runnable scripts and manifests that follow the established pattern.

After running `00-strict-enforcement-install.sh`, the cluster has:
- A bundle-signing keypair (`bundle-signer.pem` private + `bundle-signer.pub` public) generated locally and stored in a Kubernetes Secret `bundle-signer` in `zta-policy`.
- A Policy Administrator (`pa`) Deployment in `zta-policy` whose init container runs `opa build --signing-key` to produce `zta.tar.gz`, and whose nginx container serves it at `http://opa-bundle-server.zta-policy.svc.cluster.local/bundles/zta.tar.gz`.
- The OPA Deployment reconfigured via `opa-config` ConfigMap to pull bundles from the PA, verify with the public key, and reject anything that doesn't verify.
- The `pa-policies` ConfigMap built from Lab 4's Rego (no duplication).
- After step 5: two consecutive identical-credential requests producing different decisions (403 then 200) because the operator manually flipped the api pod's `zta.posture` annotation from `tampered` (left by Lab 5) to `trusted`.

## Files to create

All files in `files/zta-homelab/labs/06-strict-enforcement/`.

| File | Source (index.html) | Purpose |
|---|---|---|
| `.gitignore` | — | Excludes `keys/` (RSA keypair) and the runtime-generated `03-opa-config.yaml` (contains the public key) |
| `01-keys.sh` | line 5796 | Generate keypair to `$SCRIPT_DIR/keys/`; create Secret from those files (idempotent — only generates if missing) |
| `01-verify.sh` | line 5811 | 5 narrative checks: keys exist, RSA-2048, modulus match, Secret has both keys, no private key in any ConfigMap |
| `02-pa.yaml` | line 5846 | Deployment (init+nginx) + Service. ConfigMap is built dynamically by the orchestrator from `../04-dynamic-policy/01-zta.authz.rego`. |
| `02-verify.sh` | line 5914 | 5 narrative checks: PA 1/1, init log shows built bundle, nginx serves bundle (HTTP 200, Content-Length>0), bundle contains `.signatures.json`, Service endpoint populated |
| `03-opa-config.yaml.tmpl` | line 5948 | Template with `__BUNDLE_SIGNER_PUB__` placeholder (the doc has `<paste contents of keys/bundle-signer.pub here>`); orchestrator substitutes at install time |
| `03-verify.sh` | line 5997 | 4 narrative checks: ConfigMap defines bundles/services/signing/keys, PA URL is the cluster service, signing.keyid matches keys, no placeholder remains |
| `04-verify.sh` | line 6048 | 4 narrative checks: bundle name=zta errors=null, last_successful_activation recent (<60 s), API request returns 200 with trusted posture, `/v1/policies` lists `bundles/zta/...` paths |
| `05-close-loop.sh` | line 6088 | Round 1 deny → annotate `trusted` → force pod delete → rollout status → Round 2 allow |
| `05-verify.sh` | line 6119 | 4 narrative checks: ≥1 deny + ≥1 allow in last 60 s, reasons cover device-tampered + ok, 2 distinct decision_ids, api pod creationTimestamp recent |
| `06-break-it.sh` | line 6168 | Manual exercise (NOT run by install): adversary pod builds unsigned bundle to demonstrate verification rejection |
| `00-strict-enforcement-install.sh` | — | Orchestrator |
| `verify.sh` | line 6151 | Umbrella pass/fail validation |

## Orchestrator behaviour

Mirrors Lab 5 structure exactly. `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab06)`.

### Step functions

1. `step_01_keys` — runs `01-keys.sh` (generates keypair if missing; creates Secret idempotently). Then `01-verify.sh`.
2. `step_02_pa` — builds the `pa-policies` ConfigMap dynamically from `../04-dynamic-policy/01-zta.authz.rego`:
   ```bash
   kubectl create configmap pa-policies -n zta-policy \
     --from-file=zta.authz.rego=../04-dynamic-policy/01-zta.authz.rego \
     --dry-run=client -o yaml \
     | kubectl apply --server-side --field-manager=zta-lab06 -f -
   ```
   Then `kubectl apply` `02-pa.yaml`. Then `kubectl rollout status deploy/pa -n zta-policy --timeout=180s`. Then `02-verify.sh`.
3. `step_03_opa_config` — generates `03-opa-config.yaml` from the template:
   ```bash
   pub=$(cat keys/bundle-signer.pub)
   awk -v key="$pub" '{ if ($0 ~ /__BUNDLE_SIGNER_PUB__/) { print key } else { print } }' \
     03-opa-config.yaml.tmpl > 03-opa-config.yaml
   ```
   The template's placeholder line is the entire `__BUNDLE_SIGNER_PUB__` string standing in for the multi-line PEM. The awk above replaces that line with the multi-line public key (which already has the proper indentation since the placeholder is on its own line under `key: |`). Then `kubectl apply -f 03-opa-config.yaml` and `03-verify.sh`.
4. `step_04_apply_opa` — `kubectl rollout restart deploy/opa -n zta-policy`, `rollout status` (180s), then `04-verify.sh`. The OPA pod restart picks up the new ConfigMap mount and pulls the bundle from the PA.
5. `step_05_close_loop` — runs `bash 05-close-loop.sh` (acquires token, hits api, expects 403, annotates pod trusted, force-deletes, waits, hits api, expects 200). Then `05-verify.sh`.

After all steps: `echo "Lab 6 install completed successfully."`

## Special handling

### Template substitution for `03-opa-config.yaml`

The template `03-opa-config.yaml.tmpl` contains:

```yaml
keys:
  zta-bundle-key:
    algorithm: RS256
    key: |
      __BUNDLE_SIGNER_PUB__
```

The placeholder `__BUNDLE_SIGNER_PUB__` is on its own line under `key: |` (literal block scalar). The orchestrator's awk replaces that single line with the multi-line public key. The public key from `openssl rsa -pubout` is already in PEM format (`-----BEGIN PUBLIC KEY-----` … `-----END PUBLIC KEY-----`), and the awk preserves the indentation of subsequent lines because each line of the inserted PEM starts at column 0 — but the YAML block scalar requires consistent indentation. **Solution:** the awk computes the existing indent of the placeholder line and prepends it to each line of the public key.

Practical pattern:

```bash
# Get indent (whitespace prefix) of the placeholder line in the template.
indent=$(grep '__BUNDLE_SIGNER_PUB__' 03-opa-config.yaml.tmpl | sed 's/__BUNDLE_SIGNER_PUB__.*//')
# Build replacement: each line of the pub key prefixed with that indent.
pub_indented=$(sed "s/^/$indent/" keys/bundle-signer.pub)
# Substitute. Use a sentinel that doesn't appear in PEM content.
awk -v key="$pub_indented" '$0 ~ /__BUNDLE_SIGNER_PUB__/ { print key; next } { print }' \
  03-opa-config.yaml.tmpl > 03-opa-config.yaml
```

The generated `03-opa-config.yaml` is `.gitignore`d.

### OPA Deployment patch volumeMount/volume

The doc's `03-opa-config.yaml` Deployment patch only shows args:

```yaml
- "--config-file=/config/config.yaml"
```

…but does NOT include `volumeMounts` or `volumes`. Lab 4's patch left the OPA Deployment with a `/policies` mount and a `policy` volume bound to `opa-policy`. Lab 6 needs `/config` mount → `opa-config` ConfigMap. Without this, OPA can't find `/config/config.yaml` and fails to start. **Deviation from doc — necessary:** our template adds:

```yaml
        volumeMounts:
        - { name: config, mountPath: /config }
      volumes:
      - { name: config, configMap: { name: opa-config } }
```

### OPA `/status` queries via `kubectl exec`

The doc's verifies use `curl http://<clusterIP>:8282/status` from the host. Docker Desktop doesn't reliably route clusterIPs from the host. Adapted to:

```bash
kubectl exec deploy/opa -n zta-policy -- wget -qO- http://localhost:8282/status
```

### Idempotency

- `01-keys.sh`: `[ -f keys/bundle-signer.pem ] || openssl genrsa ...` — only generates if missing. The Secret create is `--dry-run=client | kubectl apply` — idempotent.
- ConfigMap dynamic build: idempotent.
- Template substitution: idempotent (regenerates same file each run).
- `kubectl apply --server-side`: idempotent.
- Step 5 forces a pod delete each run; the api pod will be re-created by the Deployment. Fine on re-runs.

## Out of scope

- Bootstrap (Falco, Istio, OPA in `zta-policy`, Keycloak).
- Labs 1–5 (in particular: Lab 4's Rego is the source for the PA bundle; Lab 5 leaves the api pod's posture annotation as `tampered` — step 5 of this lab clears it).
- Master install script.
- Break-it cleanup is manual.

## Acceptance criteria

After running `00-strict-enforcement-install.sh` on a cluster with bootstrap + Labs 1–5 already applied:

1. The orchestrator completes without aborting.
2. `verify.sh` exits 0 with all assertions PASS.
3. `kubectl -n zta-policy get secret bundle-signer` exists with both keys (private + public).
4. `kubectl -n zta-policy get deploy pa` reports `1/1`; the nginx container serves a non-empty `bundles/zta.tar.gz` containing `.signatures.json`.
5. `kubectl exec -n zta-policy deploy/opa -- wget -qO- http://localhost:8282/status | jq '.bundles.zta.errors'` returns `null`.
6. `kubectl exec -n zta-policy deploy/opa -- wget -qO- http://localhost:8181/v1/policies` lists policy IDs starting with `bundles/zta/`.
7. After step 5: OPA decision log contains both a `device-tampered` deny and an `ok` allow in the last 60 s with distinct `decision_id`s.
8. The api pod's annotation `zta.posture` is `trusted` (set in step 5).
9. Re-running the orchestrator on the same cluster does not error out.

## File-by-file source mapping

YAML files are **verbatim** from `index.html` `<pre><code>` blocks (HTML entities decoded), with the following specific edits:

- `02-pa.yaml`: the doc's first ConfigMap (with `# (the Lab 4 Rego, unchanged)`) is **omitted** — the orchestrator builds it dynamically. The Deployment + Service are kept verbatim.
- `03-opa-config.yaml.tmpl`: the doc's `<paste contents of keys/bundle-signer.pub here>` is replaced by `__BUNDLE_SIGNER_PUB__` (a single-line sentinel for predictable awk substitution). The Deployment patch additionally includes `volumeMounts`/`volumes` for `/config` (necessary for correctness — see "OPA Deployment patch volumeMount/volume").
- `04-verify.sh` and `05-verify.sh`: `curl http://<clusterIP>:8282/status` is rewritten to `kubectl exec deploy/opa -- wget -qO- http://localhost:8282/status`.
- `01-keys.sh`: paths use `$SCRIPT_DIR/keys/` instead of the doc's `labs/06-strict-enforcement/keys/`.
- `04-verify.sh` and `05-close-loop.sh`: `source labs/03-per-session/.env` is rewritten to `source "$SCRIPT_DIR/../03-per-session/.env"`.

Per-step verify scripts follow the narrative pattern (no shebang, no `set -e`, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script using the `check` helper.

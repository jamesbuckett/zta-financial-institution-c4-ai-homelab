# Lab 6 — Strict Enforcement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Lab 6's snippets from `index.html` (lines 5568–6196) into runnable scripts and manifests following the established Lab 1–5 pattern.

**Architecture:** Files in `files/zta-homelab/labs/06-strict-enforcement/`. Bash + YAML + a YAML *template*. The PA's `pa-policies` ConfigMap is built dynamically from Lab 4's Rego (no duplication). The OPA bundle config (`03-opa-config.yaml`) is generated at install time by substituting the public key into a `.tmpl` (avoids committing the key).

**Tech Stack:** bash 5+, openssl, kubectl, jq, yq, curl, awk, sed. Cluster: bootstrap-installed OPA in `zta-policy`, plus everything from Labs 1–5.

**Spec:** `docs/superpowers/specs/2026-04-26-lab-6-strict-enforcement-design.md`

**Pattern reference:**
- `files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh` — most-recent orchestrator
- `files/zta-homelab/labs/05-posture-monitoring/verify.sh` — most-recent umbrella

**Important pattern note:** Per-step verify scripts are *narrative* (printf headings, kubectl/curl verbatim, `# Expected:` comments — no `set -e`, no shebang, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script.

---

## File Structure

All files in `files/zta-homelab/labs/06-strict-enforcement/`:

```
.gitignore                          # Excludes keys/ and 03-opa-config.yaml
01-keys.sh                          # Generate RSA keypair + Secret
01-verify.sh                        # Step 1 narrative verify
02-pa.yaml                          # Step 2: PA Deployment + Service (ConfigMap built dynamically)
02-verify.sh                        # Step 2 narrative verify
03-opa-config.yaml.tmpl             # Step 3 template (placeholder for public key)
03-verify.sh                        # Step 3 narrative verify (asserts the generated yaml)
04-verify.sh                        # Step 4 narrative verify (kubectl-exec'd OPA /status)
05-close-loop.sh                    # Step 5: round-1 deny → remediate → round-2 allow
05-verify.sh                        # Step 5 narrative verify
06-break-it.sh                      # Manual break-it (NOT run by orchestrator)
00-strict-enforcement-install.sh    # Orchestrator
verify.sh                           # Umbrella pass/fail
```

Runtime-generated (NOT committed):
```
keys/bundle-signer.pem              # Private key (gitignored)
keys/bundle-signer.pub              # Public key (gitignored)
03-opa-config.yaml                  # Generated from .tmpl + pub key (gitignored)
```

---

## Pre-flight

- [ ] **Step P.1: Verify clean tree on main**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
git rev-parse --abbrev-ref HEAD
```
Expected: clean, `main`.

- [ ] **Step P.2: Verify spec exists and lab dir is empty**

```bash
ls -l docs/superpowers/specs/2026-04-26-lab-6-strict-enforcement-design.md
ls files/zta-homelab/labs/06-strict-enforcement/
```
Expected: spec present; lab dir empty.

---

### Task 1: `.gitignore`

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
keys/
03-opa-config.yaml
```

- [ ] **Step 2: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/.gitignore
git commit -m "$(cat <<'EOF'
Add Lab 6 .gitignore (excludes keys/ and generated opa-config)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 01 — keypair + Secret

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/01-keys.sh`
- Create: `files/zta-homelab/labs/06-strict-enforcement/01-verify.sh`

- [ ] **Step 1: Create `01-keys.sh`** (from index.html line 5796; SCRIPT_DIR-relative, idempotent — only generates if missing)

```bash
#!/usr/bin/env bash
# Generate the RSA-2048 bundle-signing keypair and store both halves in a
# Kubernetes Secret. Idempotent: keys are generated only if missing on disk;
# the Secret create uses --dry-run | apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$SCRIPT_DIR/keys"
mkdir -p "$KEYS"

if [ ! -s "$KEYS/bundle-signer.pem" ] || [ ! -s "$KEYS/bundle-signer.pub" ]; then
  echo "Generating new RSA-2048 keypair in $KEYS ..."
  openssl genrsa -out "$KEYS/bundle-signer.pem" 2048
  openssl rsa -in "$KEYS/bundle-signer.pem" -pubout -out "$KEYS/bundle-signer.pub"
else
  echo "(reusing existing keypair in $KEYS)"
fi

kubectl --context docker-desktop -n zta-policy create secret generic bundle-signer \
  --from-file=bundle-signer.pem="$KEYS/bundle-signer.pem" \
  --from-file=bundle-signer.pub="$KEYS/bundle-signer.pub" \
  --dry-run=client -o yaml | kubectl --context docker-desktop apply -f -
```

- [ ] **Step 2: Create `01-verify.sh`** (verbatim from index.html line 5811, with paths via SCRIPT_DIR)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$SCRIPT_DIR/keys"

# 1. Both key files exist locally with sane permissions.
printf '\n== 1. Key files exist on disk ==\n'
test -s "$KEYS/bundle-signer.pem" && \
test -s "$KEYS/bundle-signer.pub" && echo OK
# Expected: OK

# 2. Private key is RSA 2048 (T6 floor — anything weaker should be rejected).
printf '\n== 2. Private key is RSA-2048 ==\n'
openssl rsa -in "$KEYS/bundle-signer.pem" -text -noout 2>/dev/null \
  | grep -E 'Private-Key:|modulus' | head -1
# Expected: Private-Key: (2048 bit, ...)

# 3. Public key matches private key (an unmatched pair would silently break verification).
printf '\n== 3. Public key modulus matches private key modulus ==\n'
PRIV_MOD=$(openssl rsa -in "$KEYS/bundle-signer.pem" -modulus -noout 2>/dev/null | sha256sum)
PUB_MOD=$(openssl rsa -pubin -in "$KEYS/bundle-signer.pub" -modulus -noout 2>/dev/null | sha256sum)
test "$PRIV_MOD" = "$PUB_MOD" && echo "match" || echo "MISMATCH"
# Expected: match

# 4. Secret has both keys.
printf '\n== 4. Secret bundle-signer has both keys ==\n'
kubectl --context docker-desktop -n zta-policy get secret bundle-signer \
  -o jsonpath='{.data}' | jq 'keys'
# Expected: ["bundle-signer.pem","bundle-signer.pub"]

# 5. Private key is NOT exposed via any unexpected ConfigMap (defence-in-depth).
printf '\n== 5. No private-key block leaked in any ConfigMap ==\n'
kubectl --context docker-desktop get cm -A -o json \
  | jq -r '.items[] | select(.data!=null) | .data | tostring' \
  | grep -c 'BEGIN RSA PRIVATE KEY' || true
# Expected: 0
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/01-keys.sh
bash -n files/zta-homelab/labs/06-strict-enforcement/01-verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/01-keys.sh \
        files/zta-homelab/labs/06-strict-enforcement/01-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/01-keys.sh \
        files/zta-homelab/labs/06-strict-enforcement/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 step 01 — bundle-signing keypair + Secret

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 02 — PA Deployment + Service

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/02-pa.yaml`
- Create: `files/zta-homelab/labs/06-strict-enforcement/02-verify.sh`

- [ ] **Step 1: Create `02-pa.yaml`** (from index.html line 5853; the doc's first ConfigMap with the Lab 4 Rego is OMITTED — built dynamically by the orchestrator)

```yaml
# Note: the pa-policies ConfigMap (containing the Lab 4 Rego) is built
# dynamically by the orchestrator from ../04-dynamic-policy/01-zta.authz.rego
# at install time. This file ships only the Deployment + Service so the
# policy source isn't duplicated.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pa
  namespace: zta-policy
  labels: { zta.resource: "true", zta.data-class: "restricted", zta.owner: "policy-coe", zta.tier-role: "control-plane" }
spec:
  replicas: 1
  selector: { matchLabels: { app: pa } }
  template:
    metadata: { labels: { app: pa, zta.resource: "true", zta.data-class: "restricted", zta.owner: "policy-coe", zta.tier-role: "control-plane" } }
    spec:
      initContainers:
      - name: build
        image: openpolicyagent/opa:0.68.0
        command:
        - sh
        - -c
        - |
          set -e
          mkdir -p /out/bundles
          opa build -b /policies \
            --signing-alg RS256 \
            --signing-key /keys/bundle-signer.pem \
            --bundle \
            -o /out/bundles/zta.tar.gz
          echo 'built signed bundle:'; ls -lah /out/bundles
        volumeMounts:
        - { name: policies, mountPath: /policies, readOnly: true }
        - { name: keys,     mountPath: /keys,     readOnly: true }
        - { name: out,      mountPath: /out }
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        volumeMounts:
        - { name: out, mountPath: /usr/share/nginx/html }
        ports: [{ containerPort: 80 }]
      volumes:
      - { name: policies, configMap: { name: pa-policies } }
      - { name: keys,     secret:    { secretName: bundle-signer } }
      - { name: out,      emptyDir:  {} }
---
apiVersion: v1
kind: Service
metadata: { name: opa-bundle-server, namespace: zta-policy }
spec:
  selector: { app: pa }
  ports: [{ name: http, port: 80, targetPort: 80 }]
```

- [ ] **Step 2: Create `02-verify.sh`** (verbatim from index.html line 5914)

```bash
# 1. PA deployment is Available — init container's opa-build succeeded.
printf '\n== 1. pa Deployment is 1/1 ready ==\n'
kubectl --context docker-desktop -n zta-policy get deploy pa \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

# 2. The init log proves opa build emitted a tarball.
printf '\n== 2. init container log shows built signed bundle ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/pa -c build --tail=20 \
  | grep -E 'built signed bundle|zta\.tar\.gz'
# Expected: a 'built signed bundle:' line and an ls entry showing zta.tar.gz

# 3. nginx is serving the bundle path with a non-zero Content-Length.
printf '\n== 3. nginx serves /bundles/zta.tar.gz with HTTP 200 ==\n'
PA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=pa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $PA_POD -c nginx -- \
  wget -qS -O /dev/null http://localhost/bundles/zta.tar.gz 2>&1 \
  | grep -E 'HTTP/1\.[01] 200|Content-Length:'
# Expected: HTTP/1.1 200 and a Content-Length > 0

# 4. The bundle contains a .signatures.json file — proves the signer ran.
printf '\n== 4. Bundle tarball contains .signatures.json ==\n'
kubectl --context docker-desktop -n zta-policy exec $PA_POD -c nginx -- \
  sh -c 'tar -tzf /usr/share/nginx/html/bundles/zta.tar.gz' \
  | grep -E '^\.signatures\.json|signatures\.json'
# Expected: .signatures.json (or similar — the OPA bundle signing manifest)

# 5. Service routes to the PA (cluster IP populated, endpoints non-empty).
printf '\n== 5. Service opa-bundle-server has 1 endpoint ==\n'
kubectl --context docker-desktop -n zta-policy get endpoints opa-bundle-server \
  -o jsonpath='{.subsets[0].addresses[*].ip}{"\n"}' | wc -w
# Expected: 1   (one PA replica)
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/02-verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/02-verify.sh
yq eval '.' files/zta-homelab/labs/06-strict-enforcement/02-pa.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/02-pa.yaml \
        files/zta-homelab/labs/06-strict-enforcement/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 step 02 — Policy Administrator (PA) Deployment + Service

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 03 — OPA bundle config (template)

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/03-opa-config.yaml.tmpl`
- Create: `files/zta-homelab/labs/06-strict-enforcement/03-verify.sh`

- [ ] **Step 1: Create `03-opa-config.yaml.tmpl`** (from index.html line 5948 with two edits: placeholder is `__BUNDLE_SIGNER_PUB__`; Deployment patch adds volumeMounts/volumes for `/config`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: opa-config, namespace: zta-policy }
data:
  config.yaml: |
    services:
      pa:
        url: http://opa-bundle-server.zta-policy.svc.cluster.local
    bundles:
      zta:
        resource: "bundles/zta.tar.gz"
        service: pa
        polling:
          min_delay_seconds: 5
          max_delay_seconds: 10
        signing:
          keyid: zta-bundle-key
    keys:
      zta-bundle-key:
        algorithm: RS256
        key: |
          __BUNDLE_SIGNER_PUB__
    decision_logs:
      console: true
---
# Set OPA to load ONLY the bundle (not the local file used in Lab 4).
# NOTE: Lab 4 left this Deployment with `/policies` mount + `policy` volume.
# We replace those with the `/config` mount + `config` volume so OPA can
# find the new opa-config ConfigMap. Without these explicit volumes the
# pod fails to find /config/config.yaml and CrashLoopBackOff.
apiVersion: apps/v1
kind: Deployment
metadata: { name: opa, namespace: zta-policy }
spec:
  template:
    spec:
      containers:
      - name: opa
        args:
        - "run"
        - "--server"
        - "--config-file=/config/config.yaml"
        - "--addr=:8181"
        - "--diagnostic-addr=:8282"
        - "--set=plugins.envoy_ext_authz_grpc.addr=:9191"
        - "--set=plugins.envoy_ext_authz_grpc.path=zta/authz/result"
        volumeMounts:
        - { name: config, mountPath: /config }
      volumes:
      - { name: config, configMap: { name: opa-config } }
```

- [ ] **Step 2: Create `03-verify.sh`** (verbatim from index.html line 5997)

```bash
# 1. opa-config ConfigMap defines a 'zta' bundle and a 'pa' service.
printf '\n== 1. opa-config ConfigMap has bundles/services/signing/keys ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | grep -E 'bundles:|services:|signing:|keys:' | sort -u
# Expected: all four lines present

# 2. The PA service URL is set to the cluster-internal name (not localhost).
printf '\n== 2. PA service URL is cluster-internal ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' \
  | yq -r '.services.pa.url'
# Expected: http://opa-bundle-server.zta-policy.svc.cluster.local

# 3. signing.keyid in the bundle config matches a key declared in keys.
printf '\n== 3. signing.keyid matches a key in keys ==\n'
yq_keyid=$(kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | yq -r '.bundles.zta.signing.keyid')
yq_keys=$(kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | yq -r '.keys | keys | .[]')
echo "$yq_keyid in $yq_keys"
echo "$yq_keys" | grep -qx "$yq_keyid" && echo OK || echo MISMATCH
# Expected: OK

# 4. The public key block is the actual PEM, not the placeholder text.
printf '\n== 4. Placeholder text not present (real key inlined) ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | grep -c '__BUNDLE_SIGNER_PUB__\|paste contents of keys'
# Expected: 0   (must NOT contain the placeholder; orchestrator inlined the real key)
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/03-verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/03-verify.sh
# Note: 03-opa-config.yaml.tmpl is NOT valid YAML (placeholder line) — skip yq check.
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/03-opa-config.yaml.tmpl \
        files/zta-homelab/labs/06-strict-enforcement/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 step 03 — OPA bundle config template + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 04 — bundle activation verify (no script)

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/04-verify.sh`

- [ ] **Step 1: Create `04-verify.sh`** (from index.html line 6048 with two edits: OPA `/status` via `kubectl exec`; `.env` path via SCRIPT_DIR)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. The bundle is named 'zta' and has no errors.
printf '\n== 1. OPA /status: bundle name=zta, errors=null ==\n'
STATUS=$(kubectl --context docker-desktop -n zta-policy exec deploy/opa -- \
  wget -qO- http://localhost:8282/status 2>/dev/null)
echo "$STATUS" | jq -r '.bundles.zta | "name=\(.name) errors=\(.errors)"'
# Expected: name=zta errors=null

# 2. last_successful_activation is recent (within 60 s).
printf '\n== 2. last_successful_activation is recent (<60s) ==\n'
ACT=$(echo "$STATUS" | jq -r '.bundles.zta.last_successful_activation')
NOW=$(date -u +%s)
ACT_TS=$(date -u -d "$ACT" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S%Z' "$ACT" +%s 2>/dev/null)
echo "act_age_s=$((NOW - ACT_TS))"
# Expected: act_age_s < 60

# 3. Make a request and confirm OPA still answers — proves the bundle ALSO
#    contains a working policy, not just a verifiable signature.
printf '\n== 3. trusted-posture request returns 200 ==\n'
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)
curl -s -o /dev/null -w 'code=%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  -H 'x-device-posture: trusted' \
  http://localhost/api/headers
# Expected: code=200   (signed bundle is enforcing the same rules as Lab 4)

# 4. Watch /v1/policies — the bundle's compiled .rego is mounted under bundles/zta.
printf '\n== 4. /v1/policies lists paths under bundles/zta/ ==\n'
kubectl --context docker-desktop -n zta-policy exec deploy/opa -- \
  wget -qO- http://localhost:8181/v1/policies | jq -r '.result[].id' | head -3
# Expected: paths beginning with /bundles/zta/ (NOT /policies/zta.authz.rego from Lab 4)
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/04-verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/04-verify.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 step 04 — bundle activation verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Step 05 — close the loop (script + verify)

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/05-close-loop.sh`
- Create: `files/zta-homelab/labs/06-strict-enforcement/05-verify.sh`

- [ ] **Step 1: Create `05-close-loop.sh`** (verbatim from index.html line 6088 with `.env` path via SCRIPT_DIR)

```bash
#!/usr/bin/env bash
# Close the loop: posture=tampered -> 403 deny, operator clears annotation,
# pod is force-deleted (skipping reconciler wait), new pod resolves the env
# var to 'trusted', second request returns 200.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

# Round 1 — denied:
curl -s -o /dev/null -w 'round1=%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: round1=403

# Operator remediates — manually clear the tampered annotation:
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1)
kubectl --context docker-desktop -n bookstore-api annotate --overwrite $POD zta.posture=trusted
# Wait for reconciler (up to ~60 s) or force a bounce:
kubectl --context docker-desktop -n bookstore-api delete $POD
kubectl --context docker-desktop -n bookstore-api rollout status deploy/api

# Round 2 — allowed:
curl -s -o /dev/null -w 'round2=%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: round2=200
```

- [ ] **Step 2: Create `05-verify.sh`** (verbatim from index.html line 6119)

```bash
# 1. Two decisions logged in the last 60 s — one deny, one allow.
printf '\n== 1. >=1 deny and >=1 allow in last 60s ==\n'
DENY=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -c 'select(.decision_id and .result.allowed==false)' | wc -l)
ALLOW=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -c 'select(.decision_id and .result.allowed==true)'  | wc -l)
echo "deny=$DENY allow=$ALLOW"
# Expected: deny >= 1  allow >= 1

# 2. Reasons are exactly 'device-tampered' (round 1) and 'ok' (round 2).
printf '\n== 2. Last two reasons are device-tampered and ok ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -r 'select(.decision_id) | .result.headers["x-zta-decision-reason"]' \
  | tail -2 | sort -u
# Expected:
#   device-tampered
#   ok

# 3. The two decision_ids differ — same Alice, different decisions, distinct audit rows.
printf '\n== 3. Last two decision_ids are distinct ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -r 'select(.decision_id) | .decision_id' | tail -2 | sort -u | wc -l
# Expected: 2

# 4. The pod that served round 2 is a DIFFERENT pod from round 1
#    (operator deletion forced a fresh ZTA_POD_POSTURE env var).
printf '\n== 4. api pod creationTimestamp is recent ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.creationTimestamp}{"\n"}'
# Expected: a recent timestamp (within a couple of minutes), proving the pod
#           is fresh — its env var resolved 'trusted' from the new annotation.
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/05-close-loop.sh
bash -n files/zta-homelab/labs/06-strict-enforcement/05-verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/05-close-loop.sh \
        files/zta-homelab/labs/06-strict-enforcement/05-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/05-close-loop.sh \
        files/zta-homelab/labs/06-strict-enforcement/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 step 05 — close the loop (deny -> remediate -> allow)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Break-it script

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/06-break-it.sh`

- [ ] **Step 1: Create `06-break-it.sh`** (adapted from index.html line 6168; framed as a manual one-shot)

```bash
#!/usr/bin/env bash
# Break-it exercise (Lab 6): demonstrate that OPA refuses an unsigned bundle.
# Approach: temporarily swap opa-config to point at a hostile (or absent)
# bundle source, observe OPA's status reports verification failure, and the
# last-known-good policy keeps serving until the bundle is restored.
#
# Run manually: bash 06-break-it.sh
# Repair: re-run 00-strict-enforcement-install.sh's step 03 to redeploy
#         the correct opa-config.
set -euo pipefail

echo "Adversary attempt: build an unsigned bundle in a transient pod and copy"
echo "it to nginx. (Manual step — requires shell into the PA pod or a writable"
echo "PV. The doc covers the theory; the easiest practical demonstration is to"
echo "inspect OPA's status when the bundle cannot be verified.)"
echo

# Inspect OPA status (will show errors=null while the legit bundle is still active).
echo "Current OPA bundle status:"
kubectl --context docker-desktop -n zta-policy exec deploy/opa -- \
  wget -qO- http://localhost:8282/status \
  | jq '.bundles.zta | {name, last_successful_activation, errors}'
# Expected on tampered/unsigned: errors contains 'verification failed' / 'signature is invalid'
# Expected on legit:             errors=null
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/06-break-it.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/06-break-it.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/06-break-it.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 break-it script (manual — show OPA verification status)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Orchestrator `00-strict-enforcement-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh`

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 6 — Strict Enforcement (NIST SP 800-207 Tenet 6) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: openssl is conditional, kubectl applies use --server-side,
# template substitution is deterministic.
#
# Prerequisite (host): openssl, kubectl, jq, yq, awk, sed, curl on PATH.
# Prerequisite (cluster): bootstrap + Labs 1-5 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab06)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CURRENT_STEP=""

on_error() {
    local exit_code=$?
    local line_no=$1
    echo
    echo "---------------------------------------------------------------"
    echo "ERROR: step '${CURRENT_STEP}' failed (exit ${exit_code}, line ${line_no})."
    echo "Aborting. Fix the issue and re-run this script."
    echo "---------------------------------------------------------------"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

pause() {
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}

run_step() {
    CURRENT_STEP="$1"; shift
    clear
    echo "==============================================================="
    echo ">>> ${CURRENT_STEP}"
    echo "==============================================================="
    "$@"
    pause
}

# ---------------------------------------------------------------------------
step_01_keys() {
    bash 01-keys.sh
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_pa() {
    # Build the pa-policies ConfigMap dynamically from Lab 4's Rego.
    kubectl --context "$KCTX" -n zta-policy create configmap pa-policies \
        --from-file=zta.authz.rego=../04-dynamic-policy/01-zta.authz.rego \
        --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-pa.yaml
    kubectl --context "$KCTX" -n zta-policy rollout status deploy/pa --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_opa_config() {
    # Substitute the public key into the template and write the generated yaml.
    # The placeholder __BUNDLE_SIGNER_PUB__ is on its own line under `key: |`,
    # so we must preserve indentation when inserting the multi-line PEM.
    local indent
    indent=$(grep '__BUNDLE_SIGNER_PUB__' 03-opa-config.yaml.tmpl \
             | sed 's/__BUNDLE_SIGNER_PUB__.*//')
    local pub_indented
    pub_indented=$(sed "s/^/$indent/" keys/bundle-signer.pub)
    awk -v key="$pub_indented" '
      $0 ~ /__BUNDLE_SIGNER_PUB__/ { print key; next }
      { print }
    ' 03-opa-config.yaml.tmpl > 03-opa-config.yaml

    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-opa-config.yaml
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_apply_opa() {
    kubectl --context "$KCTX" -n zta-policy rollout restart deploy/opa
    kubectl --context "$KCTX" -n zta-policy rollout status  deploy/opa --timeout=180s
    # Give OPA a few seconds to download and verify the first bundle.
    echo "Waiting 15 s for OPA to download and activate the signed bundle..."
    sleep 15
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_close_loop() {
    bash 05-close-loop.sh
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-keys"         step_01_keys
run_step "02-pa"           step_02_pa
run_step "03-opa-config"   step_03_opa_config
run_step "04-apply-opa"    step_04_apply_opa
run_step "05-close-loop"   step_05_close_loop

echo
echo "Lab 6 install completed successfully."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/06-strict-enforcement/verify.sh`

- [ ] **Step 1: Create `verify.sh`**

```bash
#!/usr/bin/env bash
# Lab 6 — Strict Enforcement (NIST SP 800-207 Tenet 6).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion.
set -euo pipefail
CTX=${CTX:-docker-desktop}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n' "$label"; fail=$((fail+1))
  fi
}
section() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
section "Step 01 — keypair + Secret"

check "Secret bundle-signer exists in zta-policy" \
  kubectl --context "$CTX" -n zta-policy get secret bundle-signer

check "Secret carries both bundle-signer.pem and bundle-signer.pub" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy get secret bundle-signer \
                  -o jsonpath='{.data}' | jq -r 'keys | join(\",\")' \
                  | tr ',' '\\n' | sort | tr '\\n' ',')\" = 'bundle-signer.pem,bundle-signer.pub,' ]"

check "no ConfigMap leaks BEGIN RSA PRIVATE KEY" \
  bash -c "[ \"\$(kubectl --context $CTX get cm -A -o json \
                  | jq -r '.items[] | select(.data!=null) | .data | tostring' \
                  | grep -c 'BEGIN RSA PRIVATE KEY')\" = '0' ]"

# ---------------------------------------------------------------------------
section "Step 02 — Policy Administrator"

check "pa Deployment is 1/1 ready" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy get deploy pa \
                  -o jsonpath='{.status.readyReplicas}/{.status.replicas}')\" = '1/1' ]"

check "pa-policies ConfigMap declares package zta.authz" \
  bash -c "kubectl --context $CTX -n zta-policy get cm pa-policies \
            -o jsonpath='{.data.zta\\.authz\\.rego}' | grep -qx 'package zta.authz'"

check "PA nginx serves bundles/zta.tar.gz with 200 OK" \
  bash -c "pa=\$(kubectl --context $CTX -n zta-policy get pod -l app=pa -o name | head -1) && \
           kubectl --context $CTX -n zta-policy exec \"\$pa\" -c nginx -- \
             wget -qS -O /dev/null http://localhost/bundles/zta.tar.gz 2>&1 \
             | grep -q 'HTTP/1\\.[01] 200'"

check "Bundle tarball contains a signatures file" \
  bash -c "pa=\$(kubectl --context $CTX -n zta-policy get pod -l app=pa -o name | head -1) && \
           kubectl --context $CTX -n zta-policy exec \"\$pa\" -c nginx -- \
             sh -c 'tar -tzf /usr/share/nginx/html/bundles/zta.tar.gz' \
             | grep -qE 'signatures\\.json'"

check "Service opa-bundle-server has at least one endpoint" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy get endpoints opa-bundle-server \
                  -o jsonpath='{.subsets[0].addresses[*].ip}' | wc -w)\" -ge 1 ]"

# ---------------------------------------------------------------------------
section "Step 03 — OPA bundle config"

check "opa-config ConfigMap exists" \
  kubectl --context "$CTX" -n zta-policy get cm opa-config

check "opa-config has bundles.zta entry" \
  bash -c "kubectl --context $CTX -n zta-policy get cm opa-config \
            -o jsonpath='{.data.config\\.yaml}' | yq -e '.bundles.zta' >/dev/null"

check "opa-config signing.keyid matches a declared key" \
  bash -c "cm=\$(kubectl --context $CTX -n zta-policy get cm opa-config \
                  -o jsonpath='{.data.config\\.yaml}') && \
           kid=\$(echo \"\$cm\" | yq -r '.bundles.zta.signing.keyid') && \
           echo \"\$cm\" | yq -r '.keys | keys | .[]' | grep -qx \"\$kid\""

check "opa-config does NOT contain placeholder text" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy get cm opa-config \
                  -o jsonpath='{.data.config\\.yaml}' \
                  | grep -c '__BUNDLE_SIGNER_PUB__\\|paste contents of keys')\" = '0' ]"

# ---------------------------------------------------------------------------
section "Step 04 — bundle activated"

check "OPA /status reports bundle name=zta with errors=null" \
  bash -c "out=\$(kubectl --context $CTX -n zta-policy exec deploy/opa -- \
                  wget -qO- http://localhost:8282/status 2>/dev/null) && \
           [ \"\$(echo \"\$out\" | jq -r '.bundles.zta.name')\" = 'zta' ] && \
           [ \"\$(echo \"\$out\" | jq -r '.bundles.zta.errors')\" = 'null' ]"

check "/v1/policies lists at least one bundles/zta/ path" \
  bash -c "kubectl --context $CTX -n zta-policy exec deploy/opa -- \
            wget -qO- http://localhost:8181/v1/policies \
            | jq -r '.result[].id' | grep -q '^/?bundles/zta/\\|^bundles/zta/'"

# ---------------------------------------------------------------------------
section "Step 05 — close-the-loop pattern"

check "OPA decision log contains both an allow and a deny in last 5 min" \
  bash -c "logs=\$(kubectl --context $CTX -n zta-policy logs deploy/opa --since=5m) && \
           [ \"\$(echo \"\$logs\" | jq -c 'select(.decision_id and .result.allowed==true)' | wc -l)\" -ge 1 ] && \
           [ \"\$(echo \"\$logs\" | jq -c 'select(.decision_id and .result.allowed==false)' | wc -l)\" -ge 1 ]"

check "api pod annotation zta.posture is 'trusted' (set in step 5)" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get pod -l app=api \
                  -o jsonpath='{.items[0].metadata.annotations.zta\\.posture}')\" = 'trusted' ]"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 6 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/06-strict-enforcement/verify.sh
chmod +x files/zta-homelab/labs/06-strict-enforcement/verify.sh
```

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/06-strict-enforcement/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 6 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Final smoke-check (controller runs this)

- [ ] **Step 1: List all created files**

```bash
ls -la files/zta-homelab/labs/06-strict-enforcement/
```
Expected: 13 files (`.gitignore`, orchestrator, 1 yaml, 1 yaml.tmpl, 9 shell, umbrella):
```
.gitignore
00-strict-enforcement-install.sh
01-keys.sh
01-verify.sh
02-pa.yaml
02-verify.sh
03-opa-config.yaml.tmpl
03-verify.sh
04-verify.sh
05-close-loop.sh
05-verify.sh
06-break-it.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/06-strict-enforcement/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 9 lines, all `OK`.

- [ ] **Step 3: YAML structural check (skip the .tmpl)**

```bash
yq eval '.' files/zta-homelab/labs/06-strict-enforcement/02-pa.yaml >/dev/null && echo "OK 02-pa.yaml"
```
Expected: `OK 02-pa.yaml`. (`03-opa-config.yaml.tmpl` is intentionally not valid YAML — skip.)

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope

- Bootstrap and Labs 1–5.
- Master install script.
- Lab 7.

## Dependencies (assumed present before running install)

- Bootstrap completed (OPA in `zta-policy`, Istio, Keycloak, Falco).
- Labs 1–5 completed. Step 5's "round 1 = 403" relies on Lab 5 having tampered the api pod's posture; re-running Lab 5 after Lab 6 will re-tamper.
- `openssl`, `kubectl`, `jq`, `yq`, `awk`, `sed`, `curl` on PATH.
- Cluster context `docker-desktop`.

## Self-review

**Spec coverage:**
- 13 files in spec → 13 files across Tasks 1–9. ✓
- Dynamic ConfigMap build for `pa-policies` → orchestrator step_02. ✓
- Template substitution for `03-opa-config.yaml` → orchestrator step_03 (awk + indent preservation). ✓
- OPA Deployment patch with explicit volumeMounts/volumes → Task 4 step 1. ✓
- OPA `/status` via `kubectl exec` → Tasks 5, 9 (umbrella). ✓
- Lab 3 `.env` path via SCRIPT_DIR → Tasks 5, 6. ✓
- `.gitignore` for keys + generated yaml → Task 1. ✓
- Acceptance criteria covered by umbrella checks. ✓

**Placeholder scan:** No "TBD".

**Type/identifier consistency:**
- `KCTX`, `SSA`, `SCRIPT_DIR`, `BOOKSTORE_CLIENT_SECRET`, `TOKEN`, `__BUNDLE_SIGNER_PUB__` — same names everywhere. ✓
- File names consistent across tasks. ✓
- The umbrella's `bundle-signer.pem,bundle-signer.pub,` check uses sorted-comma form for a robust order-independent assertion. ✓

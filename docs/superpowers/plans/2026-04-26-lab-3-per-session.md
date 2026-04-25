# Lab 3 — Per-Session — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the Lab 3 code snippets from `index.html` (lines 3807–4319) into runnable scripts and manifests that follow the pattern established by Labs 1 and 2.

**Architecture:** All artefacts land in `files/zta-homelab/labs/03-per-session/`. Bash scripts for steps 1/2/3 (no YAML), one Deployment+ConfigMap YAML for step 4, narrative per-step verify scripts, an orchestrator (`00-per-session-install.sh`), umbrella `verify.sh`, a break-it bash script, and a `.gitignore` for the credential file written by step 1.

**Tech Stack:** bash 5+, kubectl, jq, base64, openssl. Cluster-side: Keycloak (`/opt/keycloak/bin/kcadm.sh`), SPIRE (`/opt/spire/bin/spire-server`), spiffe-helper image. Cluster context `docker-desktop`.

**Spec:** `docs/superpowers/specs/2026-04-26-lab-3-per-session-design.md`

**Pattern reference:**
- `files/zta-homelab/labs/01-resources/00-resources-install.sh` — orchestrator pattern
- `files/zta-homelab/labs/01-resources/verify.sh` — umbrella pass/fail pattern
- `files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh` — most recent applied pattern
- `files/zta-homelab/labs/02-secured-comms/verify.sh` — most recent umbrella

**Important pattern note:** Per-step verify scripts are *narrative* (print headings via `printf`, run kubectl/etc verbatim from the doc, follow with an `# Expected:` comment — no `set -e`, no shebang). Files are made executable (`chmod +x`) to match Lab 1. The umbrella `verify.sh` is the strict pass/fail script.

---

## File Structure

All files in `files/zta-homelab/labs/03-per-session/`:

```
.gitignore                       # Excludes .env
01-keycloak-realm.sh             # Step 1: realm + client + user
01-verify.sh                     # Step 1 narrative verify
02-token-and-expiry.sh           # Step 2: acquire+decode JWT (sets TOKEN)
02-verify.sh                     # Step 2 narrative verify
03-spire-register.sh             # Step 3: SPIRE entry
03-verify.sh                     # Step 3 narrative verify
04-svid-watcher.yaml             # Step 4 manifest
04-verify.sh                     # Step 4 narrative verify
05-verify.sh                     # Step 5 narrative verify (no script — observation)
06-break-it.sh                   # Manual break-it (NOT run by install)
00-per-session-install.sh        # Orchestrator
verify.sh                        # Umbrella pass/fail
```

---

## Pre-flight

- [ ] **Step P.1: Verify clean tree on main**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
git rev-parse --abbrev-ref HEAD
```
Expected: `nothing to commit, working tree clean` and `main`.

- [ ] **Step P.2: Verify the spec exists**

```bash
ls -l docs/superpowers/specs/2026-04-26-lab-3-per-session-design.md
```
Expected: file present.

- [ ] **Step P.3: Verify the lab directory exists and is empty**

```bash
ls files/zta-homelab/labs/03-per-session/
```
Expected: empty (no output).

---

### Task 1: `.gitignore` for the lab directory

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
.env
```

- [ ] **Step 2: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/.gitignore
git commit -m "$(cat <<'EOF'
Add Lab 3 .gitignore (excludes .env credential file)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 01 — Keycloak realm bootstrap

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/01-keycloak-realm.sh`
- Create: `files/zta-homelab/labs/03-per-session/01-verify.sh`

- [ ] **Step 1: Create `01-keycloak-realm.sh`** (verbatim from index.html line 3937 with two edits: `.env` path is rewritten to use `SCRIPT_DIR`; each `kc create` is wrapped to tolerate "already exists")

```bash
#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KC_POD=$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1)

kc() { kubectl --context $CTX -n zta-identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh "$@"; }

# Tolerate "already exists" on re-run.
kc_create_ok() {
  if ! out=$(kc "$@" 2>&1); then
    if echo "$out" | grep -qiE 'already exists|conflict|409'; then
      echo "(exists, continuing) $*"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
  echo "$out"
}

kc config credentials --server http://localhost:8080 --realm master --user admin --password admin

kc_create_ok create realms -s realm=zta-bookstore -s enabled=true \
  -s accessTokenLifespan=300 \
  -s ssoSessionIdleTimeout=1800 \
  -s ssoSessionMaxLifespan=3600

kc_create_ok create clients -r zta-bookstore -s clientId=bookstore-api \
  -s protocol=openid-connect -s publicClient=false \
  -s 'redirectUris=["http://bookstore.local/*"]' \
  -s directAccessGrantsEnabled=true \
  -s serviceAccountsEnabled=false

CID=$(kc get clients -r zta-bookstore -q clientId=bookstore-api --fields id --format csv --noquotes | tail -1)
kc update clients/$CID -r zta-bookstore -s 'attributes."access.token.lifespan"=300'
SECRET=$(kc get clients/$CID/client-secret -r zta-bookstore --fields value --format csv --noquotes | tail -1)

kc_create_ok create users -r zta-bookstore -s username=alice -s enabled=true -s email=alice@zta.homelab
kc set-password -r zta-bookstore --username alice --new-password alice

echo "BOOKSTORE_CLIENT_SECRET=$SECRET" > "$SCRIPT_DIR/.env"
echo "Realm ready. Secret stored in $SCRIPT_DIR/.env"
```

- [ ] **Step 2: Create `01-verify.sh`** (verbatim from index.html line 3970, with `.env` path adjusted to `SCRIPT_DIR`)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Realm exists with the 5-minute access-token lifespan T3 demands.
printf '\n== 1. Realm OIDC discovery is reachable ==\n'
curl -s -H 'Host: keycloak.local' \
  http://localhost/realms/zta-bookstore/.well-known/openid-configuration \
  | jq -r '.issuer, .token_endpoint'
# Expected:
#   http://keycloak.local/realms/zta-bookstore
#   http://keycloak.local/realms/zta-bookstore/protocol/openid-connect/token

# 2. accessTokenLifespan is exactly 300 s (T3 — short-lived).
printf '\n== 2. accessTokenLifespan == 300 ==\n'
KC_POD=$(kubectl --context docker-desktop -n zta-identity get pod -l app=keycloak -o name | head -1)
kubectl --context docker-desktop -n zta-identity exec -i $KC_POD -- \
  /opt/keycloak/bin/kcadm.sh get realms/zta-bookstore --fields accessTokenLifespan
# Expected: "accessTokenLifespan" : 300

# 3. Confidential client and test user are present.
printf '\n== 3. Client bookstore-api and user alice present ==\n'
kubectl --context docker-desktop -n zta-identity exec -i $KC_POD -- \
  /opt/keycloak/bin/kcadm.sh get clients -r zta-bookstore -q clientId=bookstore-api \
  --fields clientId,publicClient,directAccessGrantsEnabled
# Expected: clientId=bookstore-api, publicClient=false, directAccessGrantsEnabled=true

kubectl --context docker-desktop -n zta-identity exec -i $KC_POD -- \
  /opt/keycloak/bin/kcadm.sh get users -r zta-bookstore -q username=alice --fields username,enabled
# Expected: username=alice, enabled=true

# 4. The .env file with the client secret was written and is non-empty.
printf '\n== 4. .env written with BOOKSTORE_CLIENT_SECRET ==\n'
test -s "$SCRIPT_DIR/.env" && grep -c '^BOOKSTORE_CLIENT_SECRET=' "$SCRIPT_DIR/.env"
# Expected: 1
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/01-keycloak-realm.sh
bash -n files/zta-homelab/labs/03-per-session/01-verify.sh
chmod +x files/zta-homelab/labs/03-per-session/01-keycloak-realm.sh \
        files/zta-homelab/labs/03-per-session/01-verify.sh
```
Expected: no output from `bash -n`; both files now executable.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/01-keycloak-realm.sh \
        files/zta-homelab/labs/03-per-session/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 step 01 — Keycloak realm bootstrap

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 02 — token acquisition and JWT decoding

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/02-token-and-expiry.sh`
- Create: `files/zta-homelab/labs/03-per-session/02-verify.sh`

- [ ] **Step 1: Create `02-token-and-expiry.sh`** (verbatim from index.html line 4004, with `.env` source path adjusted; ends with `export TOKEN` so the orchestrator can keep it in scope)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' \
  -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

# Decode payload (JWT is base64url; pad and decode):
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, iss, exp, iat, lifetime_s: (.exp - .iat)}'

# Expected (abbreviated):
# {
#   "sub": "...uuid...",
#   "aud": "account",
#   "iss": "http://keycloak.local/realms/zta-bookstore",
#   "exp": 1760000000,
#   "iat": 1759999700,
#   "lifetime_s": 300
# }

export TOKEN
```

- [ ] **Step 2: Create `02-verify.sh`** (verbatim from index.html line 4031, with a re-acquire fallback so it runs standalone)

```bash
# Re-acquire TOKEN if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Token has three dot-separated segments — well-formed JWT.
printf '\n== 1. JWT has three dot-separated segments ==\n'
echo "$TOKEN" | awk -F. '{print NF}'
# Expected: 3

# 2. lifetime_s == 300, alg is HS256/RS256 (whatever Keycloak issued — never 'none').
printf '\n== 2. JWT alg is RS256/HS256 (never none) and lifetime is 300 ==\n'
echo "$TOKEN" | cut -d. -f1 | base64 -d 2>/dev/null | jq '.alg, .typ'
# Expected: "RS256"  "JWT"     (alg must NOT be "none")

LIFE=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp - .iat')
echo "lifetime_s=$LIFE"
# Expected: lifetime_s=300

# 3. iss matches the realm and aud is set — token is bound to this realm.
printf '\n== 3. iss/azp/typ bind token to this realm ==\n'
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.iss, .azp, .typ'
# Expected:
#   http://keycloak.local/realms/zta-bookstore
#   bookstore-api
#   Bearer

# 4. Signature verifies against the realm JWKS — proves it isn't a forged token.
printf '\n== 4. JWKS publishes at least one signing key ==\n'
JWKS=$(curl -s -H 'Host: keycloak.local' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/certs)
echo "$JWKS" | jq '.keys | length'
# Expected: >= 1   (a signing key is published; the SDK or API gateway will use it)
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/02-token-and-expiry.sh
bash -n files/zta-homelab/labs/03-per-session/02-verify.sh
chmod +x files/zta-homelab/labs/03-per-session/02-token-and-expiry.sh \
        files/zta-homelab/labs/03-per-session/02-verify.sh
```
Expected: no output; executable bits set.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/02-token-and-expiry.sh \
        files/zta-homelab/labs/03-per-session/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 step 02 — token acquisition + JWT decoding

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 03 — SPIRE workload registration

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/03-spire-register.sh`
- Create: `files/zta-homelab/labs/03-per-session/03-verify.sh`

- [ ] **Step 1: Create `03-spire-register.sh`** (verbatim from index.html line 4063, with "entry already exists" tolerance)

```bash
#!/usr/bin/env bash
set -euo pipefail
SS=$(kubectl --context docker-desktop -n spire get pod -l app=spire-server -o name | head -1)

# Register the bookstore-api ServiceAccount as a workload (idempotent on re-run).
if ! out=$(kubectl --context docker-desktop -n spire exec -i "$SS" -- \
    /opt/spire/bin/spire-server entry create \
      -parentID spiffe://zta.homelab/spire/agent/k8s_psat/docker-desktop \
      -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
      -selector k8s:ns:bookstore-api \
      -selector k8s:sa:default \
      -x509SVIDTTL 300 \
      -jwtSVIDTTL 300 2>&1); then
  if echo "$out" | grep -qi 'similar entry already exists'; then
    echo "(entry already exists, continuing)"
  else
    echo "$out" >&2
    exit 1
  fi
else
  echo "$out"
fi
# Expected:
# Entry ID         : 7d2...
# SPIFFE ID        : spiffe://zta.homelab/ns/bookstore-api/sa/default
# Parent ID        : spiffe://zta.homelab/spire/agent/k8s_psat/docker-desktop
# X509-SVID TTL    : 300
# JWT-SVID TTL     : 300
```

- [ ] **Step 2: Create `03-verify.sh`** (verbatim from index.html line 4085)

```bash
SS=$(kubectl --context docker-desktop -n spire get pod -l app=spire-server -o name | head -1)

# 1. Entry exists for the bookstore-api workload with both selectors.
printf '\n== 1. SPIRE entry exists for bookstore-api workload ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default
# Expected: one entry with selectors k8s:ns:bookstore-api and k8s:sa:default

# 2. SVID TTL is 300 s (per-session is "short-lived", not "default 1h").
printf '\n== 2. X509-SVID TTL is 300 seconds ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
  | awk '/X509-SVID TTL/ {print $NF; exit}'
# Expected: 300

# 3. SPIRE agent reports the entry has been distributed to a node.
printf '\n== 3. SPIRE agent registered on docker-desktop node ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server agent list \
  | grep -c 'docker-desktop'
# Expected: >= 1   (one agent per node; we have one node)

# 4. No duplicate entries — exactly one canonical SPIFFE ID for this workload.
printf '\n== 4. Exactly one SPIRE entry for this SPIFFE ID ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
  | grep -c '^Entry ID'
# Expected: 1
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/03-spire-register.sh
bash -n files/zta-homelab/labs/03-per-session/03-verify.sh
chmod +x files/zta-homelab/labs/03-per-session/03-spire-register.sh \
        files/zta-homelab/labs/03-per-session/03-verify.sh
```
Expected: no output; executable bits set.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/03-spire-register.sh \
        files/zta-homelab/labs/03-per-session/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 step 03 — SPIRE workload registration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 04 — svid-watcher Deployment + ConfigMap

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/04-svid-watcher.yaml`
- Create: `files/zta-homelab/labs/03-per-session/04-verify.sh`

- [ ] **Step 1: Create `04-svid-watcher.yaml`** (verbatim from index.html line 4119)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: svid-watcher, namespace: bookstore-api, labels: { zta.resource: "true", zta.data-class: "confidential", zta.owner: "retail-api", zta.tier-role: "api" } }
spec:
  replicas: 1
  selector: { matchLabels: { app: svid-watcher } }
  template:
    metadata:
      labels: { app: svid-watcher, zta.resource: "true", zta.data-class: "confidential", zta.owner: "retail-api", zta.tier-role: "api" }
    spec:
      serviceAccountName: default
      containers:
      - name: watcher
        image: ghcr.io/spiffe/spiffe-helper:0.9.0
        args: ["-config", "/config/helper.conf"]
        volumeMounts:
        - { name: config,   mountPath: /config }
        - { name: svid-out, mountPath: /svid }
        - { name: spire-agent-socket, mountPath: /run/spire/sockets }
      - name: observer
        image: alpine:3.20
        command: ["sh","-c","apk add --no-cache openssl >/dev/null; while true; do if [ -f /svid/svid.pem ]; then openssl x509 -in /svid/svid.pem -noout -serial -enddate -subject; fi; sleep 15; done"]
        volumeMounts:
        - { name: svid-out, mountPath: /svid, readOnly: true }
      volumes:
      - name: config
        configMap:
          name: svid-helper
      - { name: svid-out, emptyDir: {} }
      - name: spire-agent-socket
        hostPath: { path: /run/spire/sockets, type: DirectoryOrCreate }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: svid-helper, namespace: bookstore-api }
data:
  helper.conf: |
    agent_address = "/run/spire/sockets/agent.sock"
    cmd = ""
    cmd_args = ""
    cert_dir = "/svid"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid.key"
    svid_bundle_file_name = "bundle.pem"
    renew_signal = "SIGUSR1"
```

- [ ] **Step 2: Create `04-verify.sh`** (verbatim from index.html line 4177)

```bash
# 1. Deployment is Available with 1/1 replicas.
printf '\n== 1. svid-watcher Deployment is 1/1 ready ==\n'
kubectl --context docker-desktop -n bookstore-api get deploy svid-watcher \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

# 2. Pod has TWO containers (helper + observer) — no Istio sidecar attached
#    because zta-lab-debug-style injection isn't disabled here, so we expect
#    THREE containers if Lab 2 is still active. Either is acceptable; the
#    helper and observer must both be present.
printf '\n== 2. watcher and observer containers are present ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=svid-watcher \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# Expected: contains 'watcher' and 'observer'

# 3. svid-helper ConfigMap is mounted and contains the agent_address path.
printf '\n== 3. svid-helper ConfigMap contains agent_address ==\n'
kubectl --context docker-desktop -n bookstore-api get configmap svid-helper \
  -o jsonpath='{.data.helper\.conf}' | grep -c agent_address
# Expected: 1

# 4. The SPIRE agent's hostPath socket is reachable from the pod
#    (an SVID file should appear within a few seconds of pod start).
printf '\n== 4. /svid/svid.pem appears in the watcher pod ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=svid-watcher -o name | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do
  if kubectl --context docker-desktop -n bookstore-api exec $POD -c observer -- \
       test -f /svid/svid.pem 2>/dev/null; then echo "svid present"; break; fi
  sleep 3
done
# Expected: svid present
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/04-verify.sh
chmod +x files/zta-homelab/labs/03-per-session/04-verify.sh
```
Expected: no output; executable bit set.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/04-svid-watcher.yaml \
        files/zta-homelab/labs/03-per-session/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 step 04 — svid-watcher Deployment + ConfigMap

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Step 05 — observe SVID rotation

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/05-verify.sh`

Step 05 has no apply — pure observation. The orchestrator sleeps 180 s before invoking this verify (so at least one rotation has happened).

- [ ] **Step 1: Create `05-verify.sh`** (verbatim from index.html line 4222, with `$TOKEN` re-acquire fallback for standalone runs)

```bash
# Re-acquire TOKEN for check #4 if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Capture roughly 3 minutes of observer output and prove the serial CHANGED.
printf '\n== 1. At least 2 distinct SVID serials in last 180 s ==\n'
LOGS=$(kubectl --context docker-desktop -n bookstore-api logs --since=180s deploy/svid-watcher -c observer)
echo "$LOGS" | awk -F= '/^serial=/ {print $2}' | awk '{print $1}' | sort -u | tee /tmp/serials.txt
SERIALS=$(wc -l < /tmp/serials.txt)
echo "distinct_serials=$SERIALS"
# Expected: distinct_serials >= 2   (at least one rotation observed in 180 s)

# 2. URI SAN names the bookstore-api workload — proves SPIRE issued the SVID.
printf '\n== 2. Observer log shows URI SAN for bookstore-api workload ==\n'
echo "$LOGS" | grep -m1 -oE 'URI:spiffe://[^[:space:]]+'
# Expected: URI:spiffe://zta.homelab/ns/bookstore-api/sa/default

# 3. notAfter is <= 5 minutes from now (NOT a long-lived cert).
printf '\n== 3. notAfter is within ~5 minutes of now ==\n'
NA=$(echo "$LOGS" | awk -F= '/notAfter/ {print $3; exit}' | awk '{$1=$1; print}')
echo "notAfter=$NA"
# Expected: notAfter is within ~5 minutes of system time
#           (date -d "$NA" +%s vs date +%s should differ by <= 320)

# 4. Tenet 3 maps cleanly: token TTL = SVID TTL = 300 s.
printf '\n== 4. Token TTL == SVID TTL == 300 ==\n'
LIFE=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp - .iat')
echo "token_ttl=$LIFE svid_ttl=300"
# Expected: token_ttl=300 svid_ttl=300   (per-session for both subject and workload)
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/05-verify.sh
chmod +x files/zta-homelab/labs/03-per-session/05-verify.sh
```
Expected: no output; executable bit set.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 step 05 — SVID rotation observation verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Break-it script

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/06-break-it.sh`

Manual exercise. The orchestrator never runs it.

- [ ] **Step 1: Create `06-break-it.sh`** (extracted from index.html line 4274; framed as a manual one-shot)

```bash
#!/usr/bin/env bash
# Break-it exercise (Lab 3): replay an expired token through Istio JWT validation.
# Demonstrates why short-lived tokens matter — Tenet 3.
#
# Run manually: bash 06-break-it.sh
# Cleanup:      kubectl --context docker-desktop -n bookstore-api delete \
#                 requestauthentication keycloak-jwt \
#                 authorizationpolicy require-valid-jwt
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture a token and wait past its lifespan:
source "$SCRIPT_DIR/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

echo "Token captured. Sleeping 310 s to let it expire..."
sleep 310

# Install a simple JWT-validation RequestAuthentication (used again in Lab 4):
cat <<'EOF' | kubectl --context docker-desktop apply -f -
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata: { name: keycloak-jwt, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  jwtRules:
  - issuer: "http://keycloak.local/realms/zta-bookstore"
    jwksUri: "http://keycloak.zta-identity.svc.cluster.local:8080/realms/zta-bookstore/protocol/openid-connect/certs"
    forwardOriginalToken: true
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: require-valid-jwt, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  action: DENY
  rules:
  - from: [{ source: { notRequestPrincipals: ["*"] } }]
EOF

curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: 401   (token is expired; Istio rejects before hitting the api pod)
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/06-break-it.sh
chmod +x files/zta-homelab/labs/03-per-session/06-break-it.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/06-break-it.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 break-it script (manual exercise)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Orchestrator `00-per-session-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/00-per-session-install.sh`

Mirrors `00-secured-comms-install.sh` exactly. Step 02's function uses `source` (not `bash`) so `TOKEN` stays in the parent shell for step 05. Step 05's function does the 180 s wait.

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 3 — Per-Session (NIST SP 800-207 Tenet 3) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: every kubectl apply is idempotent under server-side apply,
# and step 1/3 tolerate "already exists" errors.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab03)

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
step_01_keycloak_realm() {
    bash 01-keycloak-realm.sh
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_token_and_expiry() {
    # Source (not bash) so TOKEN remains in scope for step_05_watch_rotation.
    # shellcheck disable=SC1091
    source 02-token-and-expiry.sh
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_spire_register() {
    bash 03-spire-register.sh
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_svid_watcher() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-svid-watcher.yaml
    kubectl --context "$KCTX" -n bookstore-api rollout status deploy/svid-watcher --timeout=120s
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_watch_rotation() {
    echo "Waiting 180 s for at least one SVID rotation (TTL/2 = 150 s)..."
    for i in $(seq 1 180); do
        printf '\rwaited %ds / 180s' "$i"
        sleep 1
    done
    echo
    echo
    echo "--- 05-verify.sh ---"
    # TOKEN is still in scope from step_02_token_and_expiry; the verify also
    # has a re-acquire fallback if it isn't.
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-keycloak-realm"   step_01_keycloak_realm
run_step "02-token-and-expiry" step_02_token_and_expiry
run_step "03-spire-register"   step_03_spire_register
run_step "04-svid-watcher"     step_04_svid_watcher
run_step "05-watch-rotation"   step_05_watch_rotation

echo
echo "Lab 3 install completed successfully."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/00-per-session-install.sh
chmod +x files/zta-homelab/labs/03-per-session/00-per-session-install.sh
```
Expected: no output; executable bit set.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/03-per-session/00-per-session-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/03-per-session/verify.sh`

Strict pass/fail using the `check` helper from Labs 1/2.

- [ ] **Step 1: Create `verify.sh`**

```bash
#!/usr/bin/env bash
# Lab 3 — Per-Session (NIST SP 800-207 Tenet 3).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion. Run after every step or once at the end.
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
section "Step 01 — Keycloak realm"

check ".env file present with BOOKSTORE_CLIENT_SECRET" \
  bash -c "[ -s '$SCRIPT_DIR/.env' ] && grep -q '^BOOKSTORE_CLIENT_SECRET=' '$SCRIPT_DIR/.env'"

check "Keycloak realm zta-bookstore reachable via OIDC discovery" \
  bash -c "curl -sf -H 'Host: keycloak.local' \
            http://localhost/realms/zta-bookstore/.well-known/openid-configuration \
            | jq -re '.issuer' | grep -qx 'http://keycloak.local/realms/zta-bookstore'"

check "accessTokenLifespan equals 300" \
  bash -c "kc_pod=\$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1) && \
           kubectl --context $CTX -n zta-identity exec -i \"\$kc_pod\" -- \
             /opt/keycloak/bin/kcadm.sh get realms/zta-bookstore --fields accessTokenLifespan \
             | grep -q '\"accessTokenLifespan\" : 300'"

check "client bookstore-api is confidential and supports password grant" \
  bash -c "kc_pod=\$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1) && \
           kubectl --context $CTX -n zta-identity exec -i \"\$kc_pod\" -- \
             /opt/keycloak/bin/kcadm.sh get clients -r zta-bookstore -q clientId=bookstore-api \
             --fields clientId,publicClient,directAccessGrantsEnabled \
             | grep -q '\"publicClient\" : false'"

check "user alice exists and is enabled" \
  bash -c "kc_pod=\$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1) && \
           kubectl --context $CTX -n zta-identity exec -i \"\$kc_pod\" -- \
             /opt/keycloak/bin/kcadm.sh get users -r zta-bookstore -q username=alice --fields username,enabled \
             | grep -q '\"enabled\" : true'"

# ---------------------------------------------------------------------------
section "Step 02 — issued JWT shape"

# shellcheck disable=SC1091
TOKEN=$(
  source "$SCRIPT_DIR/.env"
  curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token
)

check "issued JWT has three dot-separated segments" \
  bash -c "[ \"\$(echo '$TOKEN' | awk -F. '{print NF}')\" = '3' ]"

check "JWT alg is not 'none'" \
  bash -c "echo '$TOKEN' | cut -d. -f1 | base64 -d 2>/dev/null | jq -re '.alg' | grep -qv '^none$'"

check "JWT lifetime (exp - iat) is 300" \
  bash -c "[ \"\$(echo '$TOKEN' | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp - .iat')\" = '300' ]"

check "JWT issuer matches realm" \
  bash -c "echo '$TOKEN' | cut -d. -f2 | base64 -d 2>/dev/null \
            | jq -re '.iss' | grep -qx 'http://keycloak.local/realms/zta-bookstore'"

check "realm JWKS publishes at least one signing key" \
  bash -c "[ \"\$(curl -s -H 'Host: keycloak.local' \
                  http://localhost/realms/zta-bookstore/protocol/openid-connect/certs \
                  | jq '.keys | length')\" -ge 1 ]"

# ---------------------------------------------------------------------------
section "Step 03 — SPIRE workload registration"

check "SPIRE entry exists for bookstore-api workload" \
  bash -c "ss=\$(kubectl --context $CTX -n spire get pod -l app=spire-server -o name | head -1) && \
           kubectl --context $CTX -n spire exec -i \"\$ss\" -- \
             /opt/spire/bin/spire-server entry show \
             -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
             | grep -q '^Entry ID'"

check "SPIRE entry X509-SVID TTL is 300" \
  bash -c "ss=\$(kubectl --context $CTX -n spire get pod -l app=spire-server -o name | head -1) && \
           ttl=\$(kubectl --context $CTX -n spire exec -i \"\$ss\" -- \
                  /opt/spire/bin/spire-server entry show \
                  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
                  | awk '/X509-SVID TTL/ {print \$NF; exit}') && \
           [ \"\$ttl\" = '300' ]"

check "exactly one SPIRE entry for this SPIFFE ID (no duplicates)" \
  bash -c "ss=\$(kubectl --context $CTX -n spire get pod -l app=spire-server -o name | head -1) && \
           [ \"\$(kubectl --context $CTX -n spire exec -i \"\$ss\" -- \
                  /opt/spire/bin/spire-server entry show \
                  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
                  | grep -c '^Entry ID')\" = '1' ]"

# ---------------------------------------------------------------------------
section "Step 04 — svid-watcher Deployment"

check "svid-watcher Deployment is 1/1 ready" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get deploy svid-watcher \
                  -o jsonpath='{.status.readyReplicas}/{.status.replicas}')\" = '1/1' ]"

check "watcher and observer containers both present" \
  bash -c "names=\$(kubectl --context $CTX -n bookstore-api get pod -l app=svid-watcher \
                    -o jsonpath='{.items[0].spec.containers[*].name}') && \
           echo \"\$names\" | grep -qw watcher && echo \"\$names\" | grep -qw observer"

check "svid-helper ConfigMap contains agent_address" \
  bash -c "kubectl --context $CTX -n bookstore-api get configmap svid-helper \
            -o jsonpath='{.data.helper\\.conf}' | grep -q agent_address"

check "/svid/svid.pem exists in the watcher pod" \
  bash -c "pod=\$(kubectl --context $CTX -n bookstore-api get pod -l app=svid-watcher -o name | head -1) && \
           kubectl --context $CTX -n bookstore-api exec \"\$pod\" -c observer -- test -f /svid/svid.pem"

# ---------------------------------------------------------------------------
section "Step 05 — observed rotation"

check "observer log shows URI:spiffe://zta.homelab/ns/bookstore-api/sa/default" \
  bash -c "kubectl --context $CTX -n bookstore-api logs --since=180s deploy/svid-watcher -c observer \
            | grep -q 'URI:spiffe://zta.homelab/ns/bookstore-api/sa/default'"

check "observer log has at least 1 'serial=' line in last 180 s" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api logs --since=180s deploy/svid-watcher -c observer \
                  | grep -c '^serial=')\" -ge 1 ]"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 3 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

Note: the umbrella's "rotation observed" check requires `>= 1` serial line (not `>= 2` distinct serials) because the umbrella may be run anytime — it can't always wait for a rotation. The per-step `05-verify.sh` is the strict `>= 2` check after the orchestrator's 180 s wait.

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/03-per-session/verify.sh
chmod +x files/zta-homelab/labs/03-per-session/verify.sh
```

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/03-per-session/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 3 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Final smoke-check (controller runs this)

- [ ] **Step 1: List all created files**

```bash
ls -la files/zta-homelab/labs/03-per-session/
```
Expected: 13 visible files + `.gitignore` (+ possibly `.env` if you've run step 1, which should be gitignored):
```
.gitignore
00-per-session-install.sh
01-keycloak-realm.sh
01-verify.sh
02-token-and-expiry.sh
02-verify.sh
03-spire-register.sh
03-verify.sh
04-svid-watcher.yaml
04-verify.sh
05-verify.sh
06-break-it.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/03-per-session/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 9 lines, all `OK`.

- [ ] **Step 3: YAML structural check**

```bash
yq eval '.' files/zta-homelab/labs/03-per-session/04-svid-watcher.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope (reminder)

- Master `install.sh` covering all 7 labs — separate session.
- Labs 4–7 — separate sessions.
- Bootstrap and Labs 1/2 — already complete; not modified.

## Dependencies (assumed present before running install)

- Bootstrap completed (Keycloak in `zta-identity`, SPIRE in `spire`).
- Lab 1 completed (workload labels in place).
- Lab 2 completed (mTLS strict, default-deny). Lab 3 doesn't strictly require Lab 2, but the doc's flow assumes it.
- `kubectl`, `jq`, `curl`, `base64`, `awk` on PATH.
- Cluster context `docker-desktop`.
- Host can reach `http://localhost/realms/...` (Keycloak ingress on port 80, `Host: keycloak.local`) — same assumption as the doc.

## Self-review

**Spec coverage:**
- All 13 files in spec → tasks 1–9. ✓
- `.gitignore` for `.env` → Task 1. ✓
- `01-keycloak-realm.sh` SCRIPT_DIR fix → Task 2 step 1. ✓
- "already exists" tolerance for kc/spire creates → Tasks 2 and 4. ✓
- TOKEN re-acquire fallback in `02-verify.sh` and `05-verify.sh` → Tasks 3 and 6. ✓
- Orchestrator uses `source` for step 02 → Task 8 step 1. ✓
- 180 s wait in step 05 → Task 8 step 1. ✓
- Acceptance criteria covered by umbrella → Task 9. ✓

**Placeholder scan:** No "TBD" / "TODO" / "implement later".

**Type/identifier consistency:**
- `BOOKSTORE_CLIENT_SECRET`, `TOKEN`, `SPIFFE ID spiffe://zta.homelab/ns/bookstore-api/sa/default`, `KCTX`, `SSA` — same name in every reference. ✓
- File paths consistent across tasks. ✓
- `SCRIPT_DIR` pattern consistent in `01-keycloak-realm.sh`, `02-token-and-expiry.sh`, `02-verify.sh`, `05-verify.sh`, `06-break-it.sh`, `00-per-session-install.sh`, `verify.sh`. ✓
- Umbrella's `>= 1 serial` vs per-step's `>= 2 distinct serials` — intentional difference, called out in Task 9 note. ✓

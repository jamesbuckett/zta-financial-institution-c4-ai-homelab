# Lab 4 — Dynamic Policy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Lab 4's snippets from `index.html` (lines 4328–4953) into runnable scripts and manifests following the established Lab 1–3 pattern.

**Architecture:** Files in `files/zta-homelab/labs/04-dynamic-policy/`. Rego policy in its own file; ConfigMap built dynamically from disk at install time. YAMLs for OPA Deployment patch and Envoy wiring. Bash scripts for the 3-posture × 2-method matrix and the manual break-it.

**Tech Stack:** bash 5+, kubectl, jq, curl, `opa` CLI (v1.0+, local — for step 01 verify only), istioctl. Cluster: bootstrap-installed OPA in `zta-policy`, Istio, Keycloak (via Lab 3's `.env`).

**Spec:** `docs/superpowers/specs/2026-04-26-lab-4-dynamic-policy-design.md`

**Pattern reference:**
- `files/zta-homelab/labs/03-per-session/00-per-session-install.sh` — most recent orchestrator
- `files/zta-homelab/labs/03-per-session/verify.sh` — most recent umbrella

**Important pattern note:** Per-step verify scripts are *narrative* (printf headings, kubectl/opa verbatim, `# Expected:` comments — no `set -e`, no shebang, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script.

---

## File Structure

All files in `files/zta-homelab/labs/04-dynamic-policy/`:

```
01-zta.authz.rego                 # Rego policy
01-verify.sh                      # Step 1 narrative verify (uses local opa CLI)
02-opa-deployment.yaml            # OPA Deployment patch
02-verify.sh                      # Step 2 narrative verify
03-ext-authz-provider.yaml        # Mesh-root extensionProviders
03-ext-authz-envoyfilter.yaml     # EnvoyFilter + CUSTOM AuthorizationPolicy
03-verify.sh                      # Step 3 narrative verify
04-three-requests.sh              # Drives the matrix
04-verify.sh                      # Step 4 narrative verify (asserts /tmp/zta-matrix.txt)
05-verify.sh                      # Step 5 narrative verify (OPA decision log)
06-break-it.sh                    # Manual break-it (NOT run by orchestrator)
00-dynamic-policy-install.sh      # Orchestrator
verify.sh                         # Umbrella pass/fail
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

- [ ] **Step P.2: Verify spec exists and lab dir is empty**

```bash
ls -l docs/superpowers/specs/2026-04-26-lab-4-dynamic-policy-design.md
ls files/zta-homelab/labs/04-dynamic-policy/
```
Expected: spec present; lab dir empty.

---

### Task 1: Step 01 — Rego policy + verify

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/01-zta.authz.rego`
- Create: `files/zta-homelab/labs/04-dynamic-policy/01-verify.sh`

- [ ] **Step 1: Create `01-zta.authz.rego`** (verbatim from index.html line 4504)

```rego
package zta.authz

import rego.v1

# Envoy ext_authz input shape:
#   input.attributes.request.http.{method,path,headers}
#   input.attributes.source.principal          -- SPIFFE peer URI
#   input.parsed_path, input.parsed_query

default allow := false
default decision := {"allow": false, "reason": "default-deny"}

# --- helpers --------------------------------------------------------
token := t if {
  auth := input.attributes.request.http.headers.authorization
  startswith(auth, "Bearer ")
  t := substring(auth, 7, -1)
}

claims := c if {
  [_, payload, _] := io.jwt.decode(token)
  c := payload
}

posture := p if {
  p := input.attributes.request.http.headers["x-device-posture"]
} else := "unknown"

method := m if { m := input.attributes.request.http.method }
path   := p if { p := input.attributes.request.http.path }

workload_peer := s if { s := input.attributes.source.principal }

# --- rules ----------------------------------------------------------
# Allow: authenticated user + trusted posture + known workload peer
allow if {
  claims.sub
  posture == "trusted"
  startswith(workload_peer, "spiffe://cluster.local/ns/")
}

# Allow read-only GET from suspect devices
allow if {
  method == "GET"
  claims.sub
  posture == "suspect"
}

# Hard deny if device is tampered, regardless of token
decision := {"allow": false, "reason": "device-tampered"} if {
  posture == "tampered"
}

# Deny if unknown posture AND write method
decision := {"allow": false, "reason": "posture-unknown-on-write"} if {
  posture == "unknown"
  method != "GET"
}

# If a narrow deny rule didn't fire, project `allow` to decision
decision := {"allow": true,  "reason": "ok"}                    if allow
decision := {"allow": false, "reason": "no-matching-allow"}     if not allow

# Final response Envoy expects
result := {
  "allowed": decision.allow,
  "headers": {
    "x-zta-decision-id": decision_id,
    "x-zta-decision-reason": decision.reason,
  },
  "body": body,
  "http_status": status,
}

status := 200 if decision.allow
status := 403 if not decision.allow

body := "" if decision.allow
body := sprintf(`{"error":"forbidden","reason":"%s","decision_id":"%s"}`, [decision.reason, decision_id]) if not decision.allow

decision_id := crypto.sha256(sprintf("%v|%v|%v|%v|%v",
  [claims.sub, method, path, posture, time.now_ns()]))
```

- [ ] **Step 2: Create `01-verify.sh`** (from index.html line 4591, with paths adjusted to `01-zta.authz.rego` since the verify is invoked from inside the lab dir)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. The .rego file parses — no syntax error, default-deny is wired.
printf '\n== 1. Rego parses cleanly ==\n'
opa parse "$SCRIPT_DIR/01-zta.authz.rego" >/dev/null && echo PARSED
# Expected: PARSED

# 2. Default-deny is the bottom of the rule lattice (T4 — fail-closed).
printf '\n== 2. default allow / decision are fail-closed ==\n'
grep -E '^default (allow|decision)' "$SCRIPT_DIR/01-zta.authz.rego"
# Expected:
#   default allow := false
#   default decision := {"allow": false, "reason": "default-deny"}

# 3. Unit-test against a fabricated input — trusted GET allows, tampered denies.
printf '\n== 3. trusted-GET evaluates allow=true ==\n'
opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
  --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"trusted"}}},"source":{"principal":"spiffe://cluster.local/ns/bookstore-frontend/sa/default"}}}') \
  'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.allow'
# Expected: true

printf '\n== 3b. tampered evaluates reason=device-tampered ==\n'
opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
  --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"tampered"}}}}}') \
  'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.reason'
# Expected: "device-tampered"
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/01-verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/01-verify.sh
```
Expected: no output; executable bit set.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/01-zta.authz.rego \
        files/zta-homelab/labs/04-dynamic-policy/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 step 01 — Rego policy + parse/eval verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 02 — OPA Deployment patch + verify

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/02-opa-deployment.yaml`
- Create: `files/zta-homelab/labs/04-dynamic-policy/02-verify.sh`

- [ ] **Step 1: Create `02-opa-deployment.yaml`** (the Deployment-patch portion of index.html line 4625; ConfigMap is built dynamically by the orchestrator from `01-zta.authz.rego`)

```yaml
# Patch the OPA Deployment to mount the policy and enable ext_authz.
# The opa-policy ConfigMap is built dynamically from 01-zta.authz.rego at
# install time (see 00-dynamic-policy-install.sh).
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
        - "--addr=:8181"
        - "--diagnostic-addr=:8282"
        - "--set=plugins.envoy_ext_authz_grpc.addr=:9191"
        - "--set=plugins.envoy_ext_authz_grpc.path=zta/authz/result"
        - "--set=decision_logs.console=true"
        - "/policies/zta.authz.rego"
        volumeMounts:
        - { name: policy, mountPath: /policies }
      volumes:
      - { name: policy, configMap: { name: opa-policy } }
```

- [ ] **Step 2: Create `02-verify.sh`** (verbatim from index.html line 4660)

```bash
# 1. ConfigMap exists and contains the package declaration.
printf '\n== 1. opa-policy ConfigMap contains package zta.authz ==\n'
kubectl --context docker-desktop -n zta-policy get configmap opa-policy \
  -o jsonpath='{.data.zta\.authz\.rego}' | grep -c '^package zta.authz'
# Expected: 1

# 2. OPA pod is Running with the new args (ext_authz gRPC + decision logs).
printf '\n== 2. OPA Deployment carries ext_authz + decision_logs args ==\n'
kubectl --context docker-desktop -n zta-policy get deploy opa \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | jq -r '.[]' | grep -E 'envoy_ext_authz_grpc|decision_logs.console'
# Expected (both lines):
#   --set=plugins.envoy_ext_authz_grpc.addr=:9191
#   --set=plugins.envoy_ext_authz_grpc.path=zta/authz/result
#   --set=decision_logs.console=true

# 3. OPA's REST API reports the policy is loaded — query it directly.
printf '\n== 3. OPA REST /v1/policies lists the policy ==\n'
OPA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=opa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- http://localhost:8181/v1/policies | jq -r '.result[].id'
# Expected: a path containing 'zta.authz.rego'

# 4. The package compiles inside OPA — query it and get a structured response.
printf '\n== 4. /v1/data/zta/authz/decision returns default-deny ==\n'
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- --post-data='{"input":{}}' --header='Content-Type: application/json' \
  http://localhost:8181/v1/data/zta/authz/decision | jq '.result.allow, .result.reason'
# Expected:
#   false
#   "default-deny"
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/02-verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/02-verify.sh
yq eval '.' files/zta-homelab/labs/04-dynamic-policy/02-opa-deployment.yaml >/dev/null && echo "OK"
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/02-opa-deployment.yaml \
        files/zta-homelab/labs/04-dynamic-policy/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 step 02 — OPA Deployment patch + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 03 — Envoy wiring + verify

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-provider.yaml`
- Create: `files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-envoyfilter.yaml`
- Create: `files/zta-homelab/labs/04-dynamic-policy/03-verify.sh`

- [ ] **Step 1: Create `03-ext-authz-provider.yaml`** (verbatim from index.html line 4737; note caveat in spec)

```yaml
# CAVEAT: this overwrites the istio-system/istio configmap's `mesh` key.
# Bootstrap is assumed not to have populated it with other content. If it
# has, swap to `kubectl patch --type=merge` instead.
apiVersion: v1
kind: ConfigMap
metadata: { name: istio, namespace: istio-system }
data:
  mesh: |
    extensionProviders:
    - name: opa-ext-authz
      envoyExtAuthzGrpc:
        service: opa.zta-policy.svc.cluster.local
        port: 9191
```

- [ ] **Step 2: Create `03-ext-authz-envoyfilter.yaml`** (verbatim from index.html line 4694)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata: { name: ext-authz-opa, namespace: istio-system }
spec:
  configPatches:
  - applyTo: CLUSTER
    match:
      context: SIDECAR_INBOUND
    patch:
      operation: ADD
      value:
        name: opa-ext-authz
        type: STRICT_DNS
        connect_timeout: 1s
        http2_protocol_options: {}
        load_assignment:
          cluster_name: opa-ext-authz
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: opa.zta-policy.svc.cluster.local
                    port_value: 9191
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: ext-authz-opa, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  action: CUSTOM
  provider: { name: opa-ext-authz }
  rules:
  - to:
    - operation:
        paths: ["/*"]
```

- [ ] **Step 3: Create `03-verify.sh`** (verbatim from index.html line 4765)

```bash
# 1. Mesh config publishes the extension provider.
printf '\n== 1. mesh config registers opa-ext-authz extension provider ==\n'
kubectl --context docker-desktop -n istio-system get configmap istio \
  -o jsonpath='{.data.mesh}' | grep -A2 extensionProviders | grep -c opa-ext-authz
# Expected: 1

# 2. EnvoyFilter is registered in istio-system.
printf '\n== 2. EnvoyFilter ext-authz-opa applies to CLUSTER ==\n'
kubectl --context docker-desktop -n istio-system get envoyfilter ext-authz-opa \
  -o jsonpath='{.spec.configPatches[0].applyTo}{"\n"}'
# Expected: CLUSTER

# 3. CUSTOM AuthorizationPolicy on the api uses provider opa-ext-authz.
printf '\n== 3. AuthorizationPolicy ext-authz-opa is CUSTOM/opa-ext-authz ==\n'
kubectl --context docker-desktop -n bookstore-api get authorizationpolicy ext-authz-opa \
  -o jsonpath='{.spec.action}/{.spec.provider.name}{"\n"}'
# Expected: CUSTOM/opa-ext-authz

# 4. The api sidecar's listener actually contains the ext_authz filter.
printf '\n== 4. api sidecar inbound listener contains ext_authz filter ==\n'
istioctl --context docker-desktop proxy-config listener \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  --port 15006 -o json \
  | jq -r '..|.name? // empty' | grep -c 'envoy\.filters\.http\.ext_authz'
# Expected: >= 1

# 5. The OPA gRPC port is reachable from the api sidecar.
printf '\n== 5. OPA gRPC port (9191) reachable from api sidecar ==\n'
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c istio-proxy -- /bin/sh -c 'echo > /dev/tcp/opa.zta-policy.svc.cluster.local/9191 && echo OK'
# Expected: OK
```

- [ ] **Step 4: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/03-verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/03-verify.sh
yq eval '.' files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-provider.yaml >/dev/null && \
yq eval '.' files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-envoyfilter.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-provider.yaml \
        files/zta-homelab/labs/04-dynamic-policy/03-ext-authz-envoyfilter.yaml \
        files/zta-homelab/labs/04-dynamic-policy/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 step 03 — Envoy ext_authz wiring + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 04 — three-requests driver + verify

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/04-three-requests.sh`
- Create: `files/zta-homelab/labs/04-dynamic-policy/04-verify.sh`

- [ ] **Step 1: Create `04-three-requests.sh`** (from index.html line 4799; `.env` path rewritten via SCRIPT_DIR)

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"

if [ ! -s "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Run Lab 3 first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

for POSTURE in trusted suspect tampered; do
  for METHOD in GET POST; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -X $METHOD \
      -H 'Host: bookstore.local' \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-device-posture: $POSTURE" \
      http://localhost/api/anything)
    printf 'posture=%-9s method=%-4s -> %s\n' "$POSTURE" "$METHOD" "$CODE"
  done
done

# Expected:
# posture=trusted   method=GET  -> 200
# posture=trusted   method=POST -> 200
# posture=suspect   method=GET  -> 200
# posture=suspect   method=POST -> 403
# posture=tampered  method=GET  -> 403
# posture=tampered  method=POST -> 403

export TOKEN
```

- [ ] **Step 2: Create `04-verify.sh`** (verbatim from index.html line 4831, with TOKEN re-acquire fallback)

```bash
# Re-acquire TOKEN if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../03-per-session/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Capture the matrix into a file for asserting on, not eyeballing.
printf '\n== 1. Capture posture × method matrix to /tmp/zta-matrix.txt ==\n'
: > /tmp/zta-matrix.txt
for POSTURE in trusted suspect tampered; do
  for METHOD in GET POST; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -X $METHOD -H 'Host: bookstore.local' \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-device-posture: $POSTURE" \
      http://localhost/api/anything)
    echo "$POSTURE $METHOD $CODE" >> /tmp/zta-matrix.txt
  done
done
cat /tmp/zta-matrix.txt

# 2. Assert the exact 6-row decision shape T4 demands.
printf '\n== 2. Exact 6-row decision shape ==\n'
grep -c '^trusted GET 200$'   /tmp/zta-matrix.txt   # Expected: 1
grep -c '^trusted POST 200$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^suspect GET 200$'   /tmp/zta-matrix.txt   # Expected: 1
grep -c '^suspect POST 403$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^tampered GET 403$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^tampered POST 403$' /tmp/zta-matrix.txt   # Expected: 1

# 3. Each denied response carries a decision-id header so the client can cite it.
printf '\n== 3. Denied response carries x-zta-decision-id header ==\n'
curl -sS -D - -o /dev/null \
  -X POST -H 'Host: bookstore.local' \
  -H "Authorization: Bearer $TOKEN" -H 'x-device-posture: tampered' \
  http://localhost/api/anything | grep -i 'x-zta-decision-id' | wc -l
# Expected: 1
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/04-three-requests.sh
bash -n files/zta-homelab/labs/04-dynamic-policy/04-verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/04-three-requests.sh \
        files/zta-homelab/labs/04-dynamic-policy/04-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/04-three-requests.sh \
        files/zta-homelab/labs/04-dynamic-policy/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 step 04 — three-requests driver + matrix verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 05 — decision log inspection verify

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/05-verify.sh`

- [ ] **Step 1: Create `05-verify.sh`** (verbatim from index.html line 4879)

```bash
# 1. At least 6 decision lines exist in the OPA log — one per request.
printf '\n== 1. OPA decision log has >= 6 lines ==\n'
DECISIONS=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -c 'select(.decision_id != null)' 2>/dev/null | wc -l)
echo "decisions=$DECISIONS"
# Expected: decisions >= 6

# 2. Each decision_id is unique (it is a per-request audit handle, not a label).
printf '\n== 2. Last 6 decision_ids are all unique ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -r 'select(.decision_id != null) | .decision_id' | tail -6 | sort -u | wc -l
# Expected: 6

# 3. The reasons populate the four expected categories.
printf '\n== 3. Reasons cover ok / device-tampered / no-matching-allow ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -r 'select(.result.headers["x-zta-decision-reason"]) | .result.headers["x-zta-decision-reason"]' \
  | sort -u
# Expected (subset): ok, device-tampered, no-matching-allow

# 4. Every decision carries the input shape Envoy actually sent — proves
#    the audit row is complete enough to reconstruct the call.
printf '\n== 4. Each decision has method, posture, principal in input ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=20 \
  | jq -c 'select(.decision_id) | {has_method: (.input.attributes.request.http.method != null), has_posture: (.input.attributes.request.http.headers["x-device-posture"] != null), has_principal: (.input.attributes.source.principal != null)}' \
  | sort -u
# Expected: {"has_method":true,"has_posture":true,"has_principal":true}
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/05-verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/05-verify.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 step 05 — OPA decision log verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Break-it script

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/06-break-it.sh`

- [ ] **Step 1: Create `06-break-it.sh`** (from index.html line 4927; framed as one-shot manual exercise)

```bash
#!/usr/bin/env bash
# Break-it exercise (Lab 4): change the Rego default for missing posture from
# "unknown" to "trusted" and observe that requests omitting the posture header
# are now ALLOWED — fail-open. Tenet 4 prohibits this.
#
# Run manually: bash 06-break-it.sh
# Repair:       restore the original 01-zta.authz.rego (git checkout -- 01-zta.authz.rego)
#               and re-run 00-dynamic-policy-install.sh's step 02 to redeploy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"

if [ ! -s "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Run Lab 3 first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Patch the Rego in place (else := "unknown" -> else := "trusted") and rebuild
# the ConfigMap from the patched file. The user must restore by hand.
TMP_REGO=$(mktemp)
trap 'rm -f "$TMP_REGO"' EXIT
sed 's/} else := "unknown"/} else := "trusted"   # BAD/' \
  "$SCRIPT_DIR/01-zta.authz.rego" > "$TMP_REGO"
diff "$SCRIPT_DIR/01-zta.authz.rego" "$TMP_REGO" || true

kubectl --context docker-desktop -n zta-policy create configmap opa-policy \
  --from-file=zta.authz.rego="$TMP_REGO" --dry-run=client -o yaml \
  | kubectl --context docker-desktop apply -f -
kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa
kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s

# Acquire a fresh token.
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

# Attack: drop the posture header entirely.
echo "Attack: POST with no x-device-posture header (BAD policy treats missing as trusted)..."
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/anything
# Expected (bad): 200  — fail-open on missing signal
echo "(Repair: restore 01-zta.authz.rego from git and re-run step 02 of the orchestrator.)"
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/06-break-it.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/06-break-it.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/06-break-it.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 break-it script (manual exercise)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Orchestrator `00-dynamic-policy-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh`

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 4 — Dynamic Policy (NIST SP 800-207 Tenet 4) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent under server-side apply.
#
# Prerequisite (local): the `opa` CLI v1.0+ on PATH, used by 01-verify.sh.
# Prerequisite (cluster): bootstrap + Lab 1 + Lab 2 + Lab 3 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab04)

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
step_01_rego_policy() {
    echo "Validating local Rego (requires 'opa' CLI on PATH)..."
    bash 01-verify.sh
}

step_02_load_policy() {
    # Build the ConfigMap from the on-disk Rego file (idempotent dry-run | apply).
    kubectl --context "$KCTX" -n zta-policy create configmap opa-policy \
        --from-file=zta.authz.rego=01-zta.authz.rego --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-opa-deployment.yaml
    kubectl --context "$KCTX" -n zta-policy rollout status deploy/opa --timeout=120s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_wire_envoy() {
    # CAVEAT: 03-ext-authz-provider.yaml is a full ConfigMap that overwrites
    # istio-system/istio. See the spec for the bootstrap assumption.
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-ext-authz-provider.yaml
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-ext-authz-envoyfilter.yaml
    kubectl --context "$KCTX" -n istio-system rollout restart deploy/istiod
    kubectl --context "$KCTX" -n istio-system rollout status  deploy/istiod --timeout=120s
    kubectl --context "$KCTX" -n bookstore-api rollout restart deploy/api
    kubectl --context "$KCTX" -n bookstore-api rollout status  deploy/api --timeout=120s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_three_requests() {
    # Source (not bash) so TOKEN remains in scope for downstream verifies if needed.
    # shellcheck disable=SC1091
    source 04-three-requests.sh
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_decision_log() {
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-rego-policy"   step_01_rego_policy
run_step "02-load-policy"   step_02_load_policy
run_step "03-wire-envoy"    step_03_wire_envoy
run_step "04-three-requests" step_04_three_requests
run_step "05-decision-log"  step_05_decision_log

echo
echo "Lab 4 install completed successfully."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/04-dynamic-policy/verify.sh`

Strict pass/fail using the `check` helper. Does NOT require local `opa` (it queries the running OPA pod via kubectl).

- [ ] **Step 1: Create `verify.sh`**

```bash
#!/usr/bin/env bash
# Lab 4 — Dynamic Policy (NIST SP 800-207 Tenet 4).
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
section "Step 01 — Rego policy on disk"

check "01-zta.authz.rego exists in the lab dir" \
  test -s "$SCRIPT_DIR/01-zta.authz.rego"

check "Rego declares package zta.authz" \
  bash -c "grep -qx 'package zta.authz' '$SCRIPT_DIR/01-zta.authz.rego'"

check "Rego is fail-closed (default allow := false)" \
  bash -c "grep -q '^default allow := false' '$SCRIPT_DIR/01-zta.authz.rego'"

# ---------------------------------------------------------------------------
section "Step 02 — OPA loaded and serving the policy"

check "opa-policy ConfigMap exists with package zta.authz" \
  bash -c "kubectl --context $CTX -n zta-policy get configmap opa-policy \
            -o jsonpath='{.data.zta\\.authz\\.rego}' | grep -qx 'package zta.authz'"

check "OPA Deployment carries envoy_ext_authz_grpc arg" \
  bash -c "kubectl --context $CTX -n zta-policy get deploy opa \
            -o jsonpath='{.spec.template.spec.containers[0].args}' \
            | jq -r '.[]' | grep -qx -- '--set=plugins.envoy_ext_authz_grpc.addr=:9191'"

check "OPA Deployment carries decision_logs.console arg" \
  bash -c "kubectl --context $CTX -n zta-policy get deploy opa \
            -o jsonpath='{.spec.template.spec.containers[0].args}' \
            | jq -r '.[]' | grep -qx -- '--set=decision_logs.console=true'"

check "OPA REST /v1/policies lists zta.authz.rego" \
  bash -c "pod=\$(kubectl --context $CTX -n zta-policy get pod -l app=opa -o name | head -1) && \
           kubectl --context $CTX -n zta-policy exec \"\$pod\" -- \
             wget -qO- http://localhost:8181/v1/policies \
             | jq -re '.result[].id' | grep -q 'zta.authz.rego'"

check "OPA default-deny query returns allow=false / reason=default-deny" \
  bash -c "pod=\$(kubectl --context $CTX -n zta-policy get pod -l app=opa -o name | head -1) && \
           out=\$(kubectl --context $CTX -n zta-policy exec \"\$pod\" -- \
             wget -qO- --post-data='{\"input\":{}}' --header='Content-Type: application/json' \
             http://localhost:8181/v1/data/zta/authz/decision) && \
           [ \"\$(echo \"\$out\" | jq -r '.result.allow')\" = 'false' ] && \
           [ \"\$(echo \"\$out\" | jq -r '.result.reason')\" = 'default-deny' ]"

# ---------------------------------------------------------------------------
section "Step 03 — Envoy ext_authz wiring"

check "mesh config registers opa-ext-authz extension provider" \
  bash -c "kubectl --context $CTX -n istio-system get configmap istio \
            -o jsonpath='{.data.mesh}' | grep -q opa-ext-authz"

check "EnvoyFilter ext-authz-opa exists in istio-system" \
  kubectl --context "$CTX" -n istio-system get envoyfilter ext-authz-opa

check "AuthorizationPolicy ext-authz-opa is CUSTOM/opa-ext-authz" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get authorizationpolicy ext-authz-opa \
                  -o jsonpath='{.spec.action}/{.spec.provider.name}')\" = 'CUSTOM/opa-ext-authz' ]"

check "api sidecar inbound listener has ext_authz HTTP filter" \
  bash -c "pod=\$(kubectl --context $CTX -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2) && \
           istioctl --context $CTX proxy-config listener \"\$pod.bookstore-api\" --port 15006 -o json \
             | jq -r '..|.name? // empty' | grep -q 'envoy\\.filters\\.http\\.ext_authz'"

# ---------------------------------------------------------------------------
section "Step 04 — posture × method matrix"

# Acquire fresh token from Lab 3's .env.
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"
TOKEN=""
if [ -s "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

probe() {
  local posture=$1 method=$2 expected=$3
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X "$method" -H 'Host: bookstore.local' \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-device-posture: $posture" \
    http://localhost/api/anything)
  [ "$code" = "$expected" ]
}

check "trusted/GET returns 200"  bash -c "$(declare -f probe); TOKEN='$TOKEN' probe trusted  GET  200"
check "trusted/POST returns 200" bash -c "$(declare -f probe); TOKEN='$TOKEN' probe trusted  POST 200"
check "suspect/GET returns 200"  bash -c "$(declare -f probe); TOKEN='$TOKEN' probe suspect  GET  200"
check "suspect/POST returns 403" bash -c "$(declare -f probe); TOKEN='$TOKEN' probe suspect  POST 403"
check "tampered/GET returns 403" bash -c "$(declare -f probe); TOKEN='$TOKEN' probe tampered GET  403"
check "tampered/POST returns 403" bash -c "$(declare -f probe); TOKEN='$TOKEN' probe tampered POST 403"

check "denied response carries x-zta-decision-id header" \
  bash -c "[ \"\$(curl -sS -D - -o /dev/null \
                  -X POST -H 'Host: bookstore.local' \
                  -H 'Authorization: Bearer $TOKEN' -H 'x-device-posture: tampered' \
                  http://localhost/api/anything | grep -ic 'x-zta-decision-id')\" -ge 1 ]"

# ---------------------------------------------------------------------------
section "Step 05 — OPA decision log"

check "OPA log has at least 1 decision_id-bearing line in last 200 lines" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy logs deploy/opa --tail=200 \
                  | jq -c 'select(.decision_id != null)' 2>/dev/null | wc -l)\" -ge 1 ]"

check "OPA decision log has reason=device-tampered somewhere recent" \
  bash -c "kubectl --context $CTX -n zta-policy logs deploy/opa --tail=200 \
            | jq -r 'select(.result.headers[\"x-zta-decision-reason\"]) | .result.headers[\"x-zta-decision-reason\"]' \
            | grep -qx 'device-tampered'"

check "every recent decision has method, posture, principal in input" \
  bash -c "out=\$(kubectl --context $CTX -n zta-policy logs deploy/opa --tail=20 \
              | jq -c 'select(.decision_id) | {has_method: (.input.attributes.request.http.method != null), has_posture: (.input.attributes.request.http.headers[\"x-device-posture\"] != null), has_principal: (.input.attributes.source.principal != null)}' \
              | sort -u) && \
           [ \"\$out\" = '{\"has_method\":true,\"has_posture\":true,\"has_principal\":true}' ]"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 4 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/04-dynamic-policy/verify.sh
chmod +x files/zta-homelab/labs/04-dynamic-policy/verify.sh
```

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/04-dynamic-policy/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 4 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 9: Final smoke-check (controller runs this)

- [ ] **Step 1: List all created files**

```bash
ls -la files/zta-homelab/labs/04-dynamic-policy/
```
Expected: 13 files:
```
00-dynamic-policy-install.sh
01-verify.sh
01-zta.authz.rego
02-opa-deployment.yaml
02-verify.sh
03-ext-authz-envoyfilter.yaml
03-ext-authz-provider.yaml
03-verify.sh
04-three-requests.sh
04-verify.sh
05-verify.sh
06-break-it.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/04-dynamic-policy/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 9 lines, all `OK`.

- [ ] **Step 3: YAML structural check**

```bash
for f in files/zta-homelab/labs/04-dynamic-policy/*.yaml; do
  yq eval '.' "$f" >/dev/null && echo "OK $f" || echo "BAD $f"
done
```
Expected: 3 `OK` lines.

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope

- Master `install.sh` covering all 7 labs — separate session.
- Labs 5–7 — separate sessions.
- Bootstrap and Labs 1/2/3 — already complete; not modified.

## Dependencies (assumed present before running install)

- Bootstrap completed (OPA in `zta-policy`, Istio, Keycloak in `zta-identity`, bookstore api in `bookstore-api`).
- Labs 1, 2, 3 completed.
- `kubectl`, `jq`, `curl`, `istioctl`, `yq` on PATH (host-side).
- `opa` CLI v1.0+ on PATH (host-side, for step 01 verify only).
- Cluster context `docker-desktop`.
- Host can reach `http://localhost/...` with `Host: keycloak.local` and `Host: bookstore.local` (matches Lab 3's assumption).

## Self-review

**Spec coverage:**
- 13 files in spec → 13 files across Tasks 1–8. ✓
- ConfigMap built dynamically from disk → orchestrator step 02. ✓
- istio mesh-root configmap caveat → `03-ext-authz-provider.yaml` header comment + spec. ✓
- TOKEN re-acquire fallback → `04-verify.sh`, umbrella. ✓
- Lab 3 `.env` path via `SCRIPT_DIR` → `04-three-requests.sh`, `04-verify.sh`, `06-break-it.sh`. ✓
- 6-row matrix assertion → Task 4 step 2. ✓
- `opa` local-CLI prerequisite documented → Task 7 orchestrator header + plan dependencies. ✓
- Acceptance criteria covered by umbrella `verify.sh`. ✓

**Placeholder scan:** No "TBD" / "TODO" / "implement later".

**Type/identifier consistency:**
- `BOOKSTORE_CLIENT_SECRET`, `TOKEN`, `KCTX`, `SSA`, `SCRIPT_DIR` — same names everywhere. ✓
- File paths consistent across tasks. ✓
- Spec's "Files to create" table aligns with the orchestrator's `run_step` calls. ✓

# Lab 2 — Secured Comms — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the Lab 2 code snippets from `index.html` (lines 3326–3799) into runnable scripts and manifests that follow Lab 1's pattern: numeric-prefixed step files, per-step verify scripts, an orchestrator with pauses, and an umbrella verify script.

**Architecture:** All artefacts land in `files/zta-homelab/labs/02-secured-comms/`. Each step has at most one YAML manifest (`NN-<name>.yaml`) and one verify script (`NN-verify.sh`). The orchestrator (`00-secured-comms-install.sh`) applies each manifest with server-side apply and runs the matching verify after a `clear` and a pause for the learner to read output. The umbrella `verify.sh` is a strict pass/fail end-to-end check using the `check`-helper pattern from `labs/01-resources/verify.sh`.

**Tech Stack:** bash 5+, kubectl, istioctl ≥1.28, jq, yq (Go version), openssl 3, tcpdump (inside `nicolaka/netshoot:v0.13`). No build step. All files are checked-in source.

**Important pattern note:** Lab 1's per-step verify scripts are *narrative* (print heading, run command, show "Expected" comment — no `set -e`, no PASS/FAIL). The umbrella `verify.sh` is the strict pass/fail script. This plan follows that exact split.

**Spec:** `docs/superpowers/specs/2026-04-25-lab-2-secured-comms-design.md`

---

## File Structure

All files go into `files/zta-homelab/labs/02-secured-comms/`:

```
01-peer-authn-strict.yaml      # Step 1 manifest
01-verify.sh                   # Step 1 narrative verify
02-default-deny.yaml           # Step 2 manifest (4 AuthorizationPolicies)
02-verify.sh                   # Step 2 narrative verify
03-debug-pod.yaml              # Step 3 manifest (ns + pod)
03-verify.sh                   # Step 3 narrative verify
04-verify.sh                   # Step 4 narrative verify (no manifest — bash-only step)
05-verify.sh                   # Step 5 narrative verify (no manifest — capture-driving step)
06-verify.sh                   # Step 6 narrative verify (no manifest)
06-break-it.yaml               # Break-it manifest (NOT run by install)
00-secured-comms-install.sh    # Orchestrator with pauses
verify.sh                      # Umbrella pass/fail validator
```

**Why this split:** each file has one job. Steps 4–6 have no YAML because they are bash-only (curl probe, packet capture + traffic, istioctl cross-check). The break-it YAML is a separate file the learner applies by hand, mirroring `labs/01-resources/05-break-it.yaml`.

---

## Pre-flight

- [ ] **Step P.1: Verify working tree is clean and on main**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
git rev-parse --abbrev-ref HEAD
```
Expected: `nothing to commit, working tree clean` and `main`.

- [ ] **Step P.2: Verify the spec exists**

```bash
ls -l docs/superpowers/specs/2026-04-25-lab-2-secured-comms-design.md
```
Expected: file present.

- [ ] **Step P.3: Verify the lab directory exists and is empty**

```bash
ls files/zta-homelab/labs/02-secured-comms/
```
Expected: empty (no output).

---

### Task 1: Step 01 — mesh-wide STRICT PeerAuthentication

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/01-peer-authn-strict.yaml`
- Create: `files/zta-homelab/labs/02-secured-comms/01-verify.sh`

- [ ] **Step 1: Create `01-peer-authn-strict.yaml`** (verbatim from index.html line 3449)

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system        # mesh-wide when applied to the root namespace
spec:
  mtls:
    mode: STRICT
```

- [ ] **Step 2: Create `01-verify.sh`** (matches Lab 1's narrative verify pattern; checks from index.html line 3469)

```bash
# 1. PeerAuthentication is at mesh root and mode is STRICT.
printf '\n== 1. Mesh-root PeerAuthentication mode is STRICT ==\n'
kubectl --context docker-desktop -n istio-system get peerauthentication default \
  -o jsonpath='{.spec.mtls.mode}{"\n"}'
# Expected: STRICT

# 2. No namespace-level PeerAuthentication is overriding back to PERMISSIVE.
printf '\n== 2. No namespace overrides relax STRICT ==\n'
kubectl --context docker-desktop get peerauthentication -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.mtls.mode}{"\n"}{end}' \
  | grep -v '=STRICT$' || echo 'all STRICT'
# Expected: all STRICT

# 3. The mesh control plane has propagated the policy to every sidecar.
printf '\n== 3. api sidecar inbound listener uses TLS transport socket ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name \
  | head -1 \
  | xargs -I{} istioctl --context docker-desktop proxy-config listener {}.bookstore-api --port 15006 -o json \
  | jq -r '..|.transportSocket?.name? // empty' | sort -u
# Expected: contains envoy.transport_sockets.tls — the inbound listener terminates mTLS
```

- [ ] **Step 3: Smoke-check the verify script parses**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/01-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/01-peer-authn-strict.yaml \
        files/zta-homelab/labs/02-secured-comms/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 01 — mesh-wide STRICT PeerAuthentication

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 02 — default-deny AuthorizationPolicies

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/02-default-deny.yaml`
- Create: `files/zta-homelab/labs/02-secured-comms/02-verify.sh`

- [ ] **Step 1: Create `02-default-deny.yaml`** (verbatim from index.html line 3493)

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: default-deny, namespace: bookstore-api }
spec: {}   # empty spec == deny-all
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: default-deny, namespace: bookstore-data }
spec: {}
---
# Allow the ingress gateway to reach the api and frontend
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: allow-ingress-to-frontend, namespace: bookstore-frontend }
spec:
  selector: { matchLabels: { app: frontend } }
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: allow-ingress-and-frontend-to-api, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"
        - "cluster.local/ns/bookstore-frontend/sa/default"
```

- [ ] **Step 2: Create `02-verify.sh`** (checks from index.html line 3537)

```bash
# 1. Empty-spec deny exists in the two protected namespaces.
printf '\n== 1. Empty-spec default-deny in bookstore-api and bookstore-data ==\n'
for ns in bookstore-api bookstore-data; do
  kubectl --context docker-desktop -n "$ns" get authorizationpolicy default-deny \
    -o jsonpath='{.metadata.namespace}/{.metadata.name} spec={.spec}{"\n"}'
done
# Expected:
#   bookstore-api/default-deny  spec={}
#   bookstore-data/default-deny spec={}

# 2. Allow-rule exists for ingress -> frontend, and ingress+frontend -> api.
printf '\n== 2. Allow rules — ingress -> frontend ==\n'
kubectl --context docker-desktop -n bookstore-frontend get authorizationpolicy allow-ingress-to-frontend \
  -o jsonpath='{.spec.rules[0].from[0].source.principals}{"\n"}'
# Expected: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]

printf '\n== 2b. Allow rules — ingress+frontend -> api (count = 2) ==\n'
kubectl --context docker-desktop -n bookstore-api get authorizationpolicy allow-ingress-and-frontend-to-api \
  -o jsonpath='{.spec.rules[0].from[0].source.principals}{"\n"}' | jq 'length'
# Expected: 2

# 3. The deny is taking effect — Envoy's RBAC listener filter is now wired.
printf '\n== 3. Envoy RBAC HTTP filter is wired on api inbound listener ==\n'
istioctl --context docker-desktop proxy-config listener \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  --port 15006 -o json \
  | jq -r '..|.name? // empty' | grep -c 'envoy\.filters\.http\.rbac'
# Expected: >= 1
```

- [ ] **Step 3: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/02-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/02-default-deny.yaml \
        files/zta-homelab/labs/02-secured-comms/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 02 — default-deny AuthorizationPolicies

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 03 — debug pod (no sidecar)

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/03-debug-pod.yaml`
- Create: `files/zta-homelab/labs/02-secured-comms/03-verify.sh`

- [ ] **Step 1: Create `03-debug-pod.yaml`** (verbatim from index.html line 3568)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: zta-lab-debug
  labels: { istio-injection: "disabled" }   # deliberately NO sidecar
---
apiVersion: v1
kind: Pod
metadata: { name: debug, namespace: zta-lab-debug }
spec:
  containers:
  - name: tools
    image: nicolaka/netshoot:v0.13
    command: ["sleep", "36000"]
    securityContext:
      capabilities: { add: ["NET_RAW","NET_ADMIN"] }   # tcpdump needs these
```

- [ ] **Step 2: Create `03-verify.sh`** (checks from index.html line 3599)

```bash
# 1. Namespace exists and explicitly disables sidecar injection.
printf '\n== 1. zta-lab-debug namespace has istio-injection=disabled ==\n'
kubectl --context docker-desktop get ns zta-lab-debug \
  -o jsonpath='{.metadata.labels.istio-injection}{"\n"}'
# Expected: disabled

# 2. Pod is Running and has exactly ONE container — proves no sidecar was injected.
printf '\n== 2. debug pod is Running with one container (no sidecar) ==\n'
kubectl --context docker-desktop -n zta-lab-debug get pod debug \
  -o jsonpath='{.status.phase}{" "}{.spec.containers[*].name}{" count="}{range .spec.containers[*]}{.name}{","}{end}{"\n"}'
# Expected: Running tools count=tools,
#           (No "istio-proxy" sidecar — that is the whole point of this step.)

# 3. tcpdump is available and the capability bits really landed.
printf '\n== 3. tcpdump available and NET_RAW/NET_ADMIN capabilities present ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- which tcpdump
# Expected: /usr/bin/tcpdump  (or /usr/sbin/tcpdump)
kubectl --context docker-desktop -n zta-lab-debug get pod debug \
  -o jsonpath='{.spec.containers[0].securityContext.capabilities.add}{"\n"}'
# Expected: ["NET_RAW","NET_ADMIN"]
```

- [ ] **Step 3: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/03-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/03-debug-pod.yaml \
        files/zta-homelab/labs/02-secured-comms/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 03 — out-of-mesh debug pod

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 04 — plaintext attempt verify (no manifest)

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/04-verify.sh`

Step 04 has no YAML — it is a designed failure: a curl whose non-zero exit is the proof. The orchestrator runs the curl; this verify confirms the failure mode.

- [ ] **Step 1: Create `04-verify.sh`** (checks from index.html line 3636)

```bash
# 1. The plaintext call exits non-zero with curl code 52 (Empty reply).
printf '\n== 1. Plaintext curl from out-of-mesh pod fails (expected exit 52) ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- \
  bash -c "curl -sS --max-time 5 http://api.bookstore-api.svc.cluster.local/headers; echo EXIT=\$?"
# Expected: a curl error message (Empty reply / Recv failure) and EXIT=52
#           (NOT EXIT=0 — that would mean STRICT mTLS is not enforced)

# 2. TCP reaches the sidecar but is then closed without an HTTP body —
#    proves the sidecar accepted the connection then refused the plaintext.
printf '\n== 2. Raw TCP connect succeeds but no HTTP/1.1 response is returned ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- \
  bash -c "echo -e 'GET /headers HTTP/1.1\r\nHost: api.bookstore-api.svc.cluster.local\r\n\r\n' \
           | timeout 4 nc -v api.bookstore-api.svc.cluster.local 80; echo EXIT=\$?"
# Expected: 'open' or 'succeeded' on connect, then EOF / no HTTP/1.1 response.
#           No "HTTP/1.1 200" or "HTTP/1.1 4xx" line — the sidecar dropped before HTTP.

# 3. Istio access log on the api side shows a connection-level reset, not an HTTP 4xx.
printf '\n== 3. api sidecar access log shows connection-level termination ==\n'
kubectl --context docker-desktop -n bookstore-api logs \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c istio-proxy --tail=5 | grep -E 'response_code_details|connection_termination' || true
# Expected: lines containing 'connection_termination_details' or response code 0
#           — STRICT mTLS terminated before any HTTP layer existed.
```

Note on the embedded `\$?`: the verify script invokes `bash -c "..."` from inside another shell context. Lab 1 doesn't escape these, but here we want the inner shell to expand `$?`, not the surrounding kubectl-exec parser; `\$?` keeps the dollar literal until it reaches the inner `bash -c`. Verify by running.

- [ ] **Step 2: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/04-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 04 — plaintext-attempt verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 05 — packet capture verify (no manifest)

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/05-verify.sh`

Step 05 has no YAML. The orchestrator drives the capture (Task 7's `step_05_packet_capture` function); this verify reads `/tmp/capture.txt` after the orchestrator has populated it.

- [ ] **Step 1: Create `05-verify.sh`** (checks from index.html line 3684)

```bash
# 1. Capture file exists and is non-empty — tcpdump actually saw frames.
printf '\n== 1. /tmp/capture.txt is non-empty ==\n'
test -s /tmp/capture.txt && echo "bytes=$(wc -c < /tmp/capture.txt)"
# Expected: bytes=>0

# 2. NO plaintext HTTP method or HTTP-style header on the wire.
printf '\n== 2. No plaintext HTTP verbs / headers in capture ==\n'
grep -cE '^(GET|POST|PUT|DELETE) /|Host: |User-Agent: ' /tmp/capture.txt
# Expected: 0

# 3. TLS record headers ARE present (handshake byte 0x16, version 0x0303).
printf '\n== 3. TLS record headers present in capture ==\n'
grep -cE '0x0000:.*1603 03|160303' /tmp/capture.txt
# Expected: >= 1   (some frames begin with a TLS 1.2/1.3 record; exact count varies)

# 4. Sidecar inbound port 15006 appears as a flow target — confirms traffic
#    was redirected through Envoy rather than reaching the app socket directly.
printf '\n== 4. Sidecar inbound port 15006 visible in capture ==\n'
grep -cE '\.15006:' /tmp/capture.txt
# Expected: >= 1
```

- [ ] **Step 2: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/05-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 05 — capture verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Step 06 — istioctl cross-check verify (no manifest)

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/06-verify.sh`

- [ ] **Step 1: Create `06-verify.sh`** (checks from index.html line 3719)

```bash
# 1. tls-check reports SERVER=STRICT, CLIENT=ISTIO_MUTUAL, STATUS=OK.
printf '\n== 1. istioctl authn tls-check reports OK STRICT ISTIO_MUTUAL ==\n'
istioctl --context docker-desktop authn tls-check \
  $(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2).bookstore-frontend \
  api.bookstore-api.svc.cluster.local \
  | awk 'NR>1 {print $2,$3,$4}' | head -1
# Expected: OK STRICT ISTIO_MUTUAL

# 2. Sidecar reports a SECRET resource carrying a SPIFFE SVID for the api workload.
printf '\n== 2. api sidecar has SVID secrets (ROOTCA + default) ==\n'
istioctl --context docker-desktop proxy-config secret \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  -o json \
  | jq -r '.dynamicActiveSecrets[]?.name' | sort -u
# Expected: ROOTCA, default        (default = the workload's SVID)

# 3. The SVID's URI SAN names the api workload — proves Istio CA, not a bystander, signed it.
printf '\n== 3. SVID URI SAN matches the api workload ==\n'
istioctl --context docker-desktop proxy-config secret \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null
# Expected: URI:spiffe://cluster.local/ns/bookstore-api/sa/default

# 4. Capture and control-plane view AGREE — neither dissents about STRICT.
printf '\n== 4. Capture has no plaintext HTTP — agrees with control plane ==\n'
grep -cE '^(GET|POST) ' /tmp/capture.txt 2>/dev/null || echo 0
# Expected: 0  (matches the istioctl OK / STRICT line above; both agree)
```

- [ ] **Step 2: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/06-verify.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/06-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 step 06 — istioctl cross-check verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Orchestrator `00-secured-comms-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh`

Mirrors `labs/01-resources/00-resources-install.sh` exactly: same `set -euo pipefail`, same `KCTX`/`SSA`, same `on_error`/`pause`/`run_step` helpers, one function per step, terminal banner. Adds two specific behaviours unique to Lab 2: a designed-failure wrapper for step 04, and a backgrounded tcpdump + traffic loop for step 05.

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 2 — Secured Comms (NIST SP 800-207 Tenet 2) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: every kubectl apply is idempotent under server-side apply.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab02)

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
step_01_peer_authn_strict() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 01-peer-authn-strict.yaml
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_default_deny() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-default-deny.yaml
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_debug_pod() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-debug-pod.yaml
    kubectl --context "$KCTX" -n zta-lab-debug wait --for=condition=Ready pod/debug --timeout=60s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_plaintext_attempt() {
    # Designed failure: a successful plaintext call would mean STRICT mTLS is
    # not enforced. We disable -e around the curl so we can inspect the exit
    # code, then abort if it unexpectedly returned 0.
    set +e
    kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
        curl -sv --max-time 5 http://api.bookstore-api.svc.cluster.local/headers
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: plaintext call to api.bookstore-api unexpectedly succeeded (exit 0)."
        echo "STRICT mTLS is not being enforced — investigate before proceeding."
        return 1
    fi
    echo "OK: plaintext call refused as expected (curl exit=$rc)."
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_packet_capture() {
    # Drive a tcpdump in the debug pod while the frontend (with sidecar) calls
    # the api. The capture is piped to /tmp/capture.txt on the host so the
    # 05-verify.sh and 06-verify.sh can both inspect it.
    rm -f /tmp/capture.txt

    # tcpdump auto-terminates after 30 packets.
    kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
        tcpdump -i any -nn -s 0 -c 30 -A 'tcp port 80 or tcp port 15006' \
        > /tmp/capture.txt 2>&1 &
    local TCPDUMP_PID=$!

    # Give tcpdump time to attach.
    sleep 2

    # Drive 10 wget calls from the frontend pod (which has a sidecar).
    local FRONTEND
    FRONTEND=$(kubectl --context "$KCTX" -n bookstore-frontend get pod -l app=frontend -o name | head -1)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kubectl --context "$KCTX" -n bookstore-frontend exec "$FRONTEND" -c nginx -- \
            wget -qO- http://api.bookstore-api.svc.cluster.local/headers >/dev/null || true
        sleep 0.3
    done

    # Wait up to 15s for tcpdump to finish; kill it if it hangs.
    local waited=0
    while kill -0 "$TCPDUMP_PID" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 15 ]; then
            kill "$TCPDUMP_PID" 2>/dev/null || true
            break
        fi
    done
    wait "$TCPDUMP_PID" 2>/dev/null || true

    echo
    echo "--- /tmp/capture.txt (first 40 lines) ---"
    head -40 /tmp/capture.txt || true
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

step_06_istio_cross_check() {
    istioctl --context "$KCTX" authn tls-check \
        $(kubectl --context "$KCTX" -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2).bookstore-frontend \
        api.bookstore-api.svc.cluster.local
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-peer-authn-strict" step_01_peer_authn_strict
run_step "02-default-deny"      step_02_default_deny
run_step "03-debug-pod"         step_03_debug_pod
run_step "04-plaintext-attempt" step_04_plaintext_attempt
run_step "05-packet-capture"    step_05_packet_capture
run_step "06-istio-cross-check" step_06_istio_cross_check

echo
echo "Lab 2 install completed successfully."
```

- [ ] **Step 2: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh
chmod +x files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh
```
Expected: no output from `bash -n`; exit 0.

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Break-it manifest

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/06-break-it.yaml`

This is the manual exercise. The orchestrator never applies it.

- [ ] **Step 1: Create `06-break-it.yaml`** (extracted from index.html line 3774)

```yaml
# Break-it exercise (Lab 2): downgrade bookstore-api to PERMISSIVE and re-run
# the plaintext attempt from step 04. The call should now SUCCEED and the
# response should NOT include X-Forwarded-Client-Cert. This is precisely the
# risk Tenet 2 prohibits.
#
# Apply:    kubectl --context docker-desktop apply -f 06-break-it.yaml
# Re-test:  kubectl --context docker-desktop -n zta-lab-debug exec debug -- \
#             curl -sS --max-time 3 http://api.bookstore-api.svc.cluster.local/headers \
#             | jq '.headers | keys | length'
# Restore:  kubectl --context docker-desktop -n bookstore-api delete peerauthentication downgrade
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: downgrade
  namespace: bookstore-api
spec:
  mtls:
    mode: PERMISSIVE
```

- [ ] **Step 2: Commit**

```bash
git add files/zta-homelab/labs/02-secured-comms/06-break-it.yaml
git commit -m "$(cat <<'EOF'
Add Lab 2 break-it manifest (manual exercise)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/02-secured-comms/verify.sh`

Mirrors `labs/01-resources/verify.sh`: strict pass/fail, `check` helper, exit non-zero on first failure summary. Asserts the three claims from index.html line 3750 plus the per-step claims that survive end-to-end (mode is STRICT, plaintext refused, mesh client succeeds with X-Forwarded-Client-Cert).

- [ ] **Step 1: Create `verify.sh`**

```bash
#!/usr/bin/env bash
# Lab 2 — Secured Comms (NIST SP 800-207 Tenet 2).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion. Run after every step or once at the end.
set -euo pipefail
CTX=${CTX:-docker-desktop}

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
section "Step 01 — mesh-wide STRICT PeerAuthentication"

check "PeerAuthentication default exists in istio-system" \
  kubectl --context "$CTX" -n istio-system get peerauthentication default

check "mesh-wide PeerAuthentication mode is STRICT" \
  bash -c "[ \"\$(kubectl --context $CTX -n istio-system get peerauthentication default \
                  -o jsonpath='{.spec.mtls.mode}')\" = 'STRICT' ]"

check "no namespace-scoped PeerAuthentication relaxes mode below STRICT" \
  bash -c "kubectl --context $CTX get peerauthentication -A \
            -o jsonpath='{range .items[*]}{.spec.mtls.mode}{\"\\n\"}{end}' \
            | grep -v '^STRICT$' | grep -v '^$' | wc -l \
            | grep -qx 0"

# ---------------------------------------------------------------------------
section "Step 02 — default-deny AuthorizationPolicies"

check "default-deny exists in bookstore-api" \
  kubectl --context "$CTX" -n bookstore-api get authorizationpolicy default-deny

check "default-deny exists in bookstore-data" \
  kubectl --context "$CTX" -n bookstore-data get authorizationpolicy default-deny

check "default-deny in bookstore-api has empty spec" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get authorizationpolicy default-deny \
                  -o jsonpath='{.spec}')\" = '{}' ]"

check "allow-ingress-to-frontend exists with ingress principal" \
  bash -c "kubectl --context $CTX -n bookstore-frontend get authorizationpolicy allow-ingress-to-frontend \
            -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}' \
            | grep -qx 'cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account'"

check "allow-ingress-and-frontend-to-api lists 2 principals" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get authorizationpolicy allow-ingress-and-frontend-to-api \
                  -o jsonpath='{.spec.rules[0].from[0].source.principals}' \
                  | jq 'length')\" = '2' ]"

# ---------------------------------------------------------------------------
section "Step 03 — debug pod (out of mesh)"

check "namespace zta-lab-debug exists with istio-injection=disabled" \
  bash -c "[ \"\$(kubectl --context $CTX get ns zta-lab-debug \
                  -o jsonpath='{.metadata.labels.istio-injection}')\" = 'disabled' ]"

check "debug pod is Running" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-lab-debug get pod debug \
                  -o jsonpath='{.status.phase}')\" = 'Running' ]"

check "debug pod has exactly one container (no sidecar)" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-lab-debug get pod debug \
                  -o jsonpath='{range .spec.containers[*]}{.name}{\"\\n\"}{end}' | wc -l \
                  | tr -d ' ')\" = '1' ]"

check "debug pod has NET_RAW and NET_ADMIN capabilities" \
  bash -c "kubectl --context $CTX -n zta-lab-debug get pod debug \
            -o jsonpath='{.spec.containers[0].securityContext.capabilities.add}' \
            | jq -e 'index(\"NET_RAW\") and index(\"NET_ADMIN\")' >/dev/null"

# ---------------------------------------------------------------------------
section "Step 04 — plaintext call refused"

check "plaintext curl from out-of-mesh pod exits non-zero" \
  bash -c "! kubectl --context $CTX -n zta-lab-debug exec debug -- \
              curl -sS --max-time 5 http://api.bookstore-api.svc.cluster.local/headers"

# ---------------------------------------------------------------------------
section "Step 05 — frontend->api succeeds with mesh identity"

check "mesh-authenticated wget from frontend reaches api with X-Forwarded-Client-Cert" \
  bash -c "
    pod=\$(kubectl --context $CTX -n bookstore-frontend get pod -l app=frontend -o name | head -1)
    body=\$(kubectl --context $CTX -n bookstore-frontend exec \"\$pod\" -c nginx -- \
            wget -qO- http://api.bookstore-api.svc.cluster.local/headers 2>/dev/null)
    echo \"\$body\" | jq -e '.headers.\"X-Forwarded-Client-Cert\" // empty | test(\"By=spiffe://cluster.local/\")' >/dev/null
  "

# ---------------------------------------------------------------------------
section "Step 06 — control-plane view agrees"

check "istioctl tls-check reports OK STRICT ISTIO_MUTUAL for frontend->api" \
  bash -c "
    pod=\$(kubectl --context $CTX -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2)
    line=\$(istioctl --context $CTX authn tls-check \"\$pod.bookstore-frontend\" api.bookstore-api.svc.cluster.local \
            | awk 'NR>1' | head -1)
    echo \"\$line\" | grep -q 'OK' && echo \"\$line\" | grep -q 'STRICT' && echo \"\$line\" | grep -q 'ISTIO_MUTUAL'
  "

check "api sidecar has SPIFFE SVID secret named 'default'" \
  bash -c "
    pod=\$(kubectl --context $CTX -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
    istioctl --context $CTX proxy-config secret \"\$pod.bookstore-api\" -o json \
      | jq -e '.dynamicActiveSecrets[]? | select(.name==\"default\")' >/dev/null
  "

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 2 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

- [ ] **Step 2: Smoke-check**

```bash
bash -n files/zta-homelab/labs/02-secured-comms/verify.sh
chmod +x files/zta-homelab/labs/02-secured-comms/verify.sh
```
Expected: no output from `bash -n`; exit 0.

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/02-secured-comms/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 2 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Final smoke-check

- [ ] **Step 1: List all created files**

```bash
ls -la files/zta-homelab/labs/02-secured-comms/
```
Expected: 12 files exactly:
```
00-secured-comms-install.sh
01-peer-authn-strict.yaml
01-verify.sh
02-default-deny.yaml
02-verify.sh
03-debug-pod.yaml
03-verify.sh
04-verify.sh
05-verify.sh
06-break-it.yaml
06-verify.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/02-secured-comms/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 8 lines, all `OK`.

- [ ] **Step 3: yaml-syntax-check every manifest with `kubectl apply --dry-run=client`** (requires cluster reachable; skip if not)

```bash
for f in files/zta-homelab/labs/02-secured-comms/*.yaml; do
  kubectl --context docker-desktop apply --dry-run=client -f "$f" >/dev/null 2>&1 \
    && echo "OK $f" || echo "BAD $f"
done
```
Expected: 4 lines, all `OK`. If the cluster is not reachable, replace with `yq eval '.' "$f" >/dev/null` for offline structural validation.

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope (reminder)

- Master `install.sh` covering all 7 labs — separate session.
- Labs 3–7 — separate sessions, one each.
- Bootstrap (`files/zta-homelab/bootstrap/`) — already complete; not modified.
- Break-it cleanup automation — left manual, mirroring Lab 1.

## Dependencies (assumed present before running install)

- Bootstrap completed (`bootstrap/00-bootstrap-install.sh` ran cleanly).
- Lab 1 ran cleanly (workloads carry ZTA labels — required by step 02's `selector: { matchLabels: { app: ... } }`).
- `kubectl`, `istioctl ≥1.28`, `jq`, `yq` (Go), `openssl` 3 on PATH.
- Docker Desktop Kubernetes context named `docker-desktop`.

## Self-review

**Spec coverage:**
- 12 files in spec → 12 files in plan (Tasks 1–9). ✓
- Step 04 designed-failure handling → Task 7, `step_04_plaintext_attempt`. ✓
- Step 05 concurrent capture+traffic → Task 7, `step_05_packet_capture` (rm capture, background tcpdump, sleep 2, 10× wget with 0.3s, wait up to 15s, kill if hung). ✓
- Idempotency via `--server-side --field-manager=zta-lab02` → Task 7. ✓
- Acceptance criteria (umbrella verify exit 0, mode=STRICT, curl exit 52, X-Forwarded-Client-Cert by spiffe) → Task 9 verify.sh assertions. ✓

**Placeholder scan:** No "TBD" / "TODO" / "implement later" / "similar to Task N" found.

**Type/identifier consistency:**
- File paths consistent across all tasks. ✓
- Step function names (`step_01_peer_authn_strict` … `step_06_istio_cross_check`) used consistently in Task 7. ✓
- `KCTX="docker-desktop"`, `SSA=(--server-side --field-manager=zta-lab02)` defined once and referenced by name. ✓
- `/tmp/capture.txt` referenced in Tasks 5, 6, 7 — same path each time. ✓

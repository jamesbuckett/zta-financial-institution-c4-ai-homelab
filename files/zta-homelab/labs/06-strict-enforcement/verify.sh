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

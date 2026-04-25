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

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

# OPA is configured to log decisions to the console. Lab 4 sets this via
# `--set=decision_logs.console=true` in args; Lab 6 moves the same setting
# into opa-config (config-file) and drops the arg. Accept either form so
# this check stays green after Lab 6 has been applied.
check "OPA emits decision logs to the console (via arg or config-file)" \
  bash -c "
    args=\$(kubectl --context $CTX -n zta-policy get deploy opa \
            -o jsonpath='{.spec.template.spec.containers[0].args}')
    if echo \"\$args\" | jq -r '.[]' | grep -qx -- '--set=decision_logs.console=true'; then
      exit 0
    fi
    kubectl --context $CTX -n zta-policy get cm opa-config \
      -o jsonpath='{.data.config\\.yaml}' 2>/dev/null \
      | grep -qE 'decision_logs:[[:space:]]*$|decision_logs:[[:space:]]*\\{|console:[[:space:]]*true'
  "

# OPA's distroless image has no wget/curl/shell, so probe it via a temporary
# port-forward instead of `kubectl exec`. _opa_curl wraps the lifecycle.
_opa_curl() {
  local cmd_out cmd_rc pf
  kubectl --context "$CTX" -n zta-policy port-forward svc/opa 18181:8181 >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 20); do
    curl -s --max-time 1 http://localhost:18181/health >/dev/null 2>&1 && break
    sleep 0.5
  done
  cmd_out=$(curl -s "$@")
  cmd_rc=$?
  kill "$pf" 2>/dev/null || true
  printf '%s' "$cmd_out"
  return "$cmd_rc"
}

check "OPA REST /v1/policies lists zta.authz.rego" \
  bash -c "$(declare -f _opa_curl); CTX=$CTX; \
           _opa_curl http://localhost:18181/v1/policies \
             | jq -re '.result[].id' | grep -q 'zta.authz.rego'"

# Empty-input probe: confirm fail-closed. Lab 4's policy returns
# reason="default-deny"; Lab 7's refined policy returns "missing-token"
# for the same empty-input case (it splits the catch-all into more
# specific reasons). Accept either as proof that the deny path is wired.
check "OPA fail-closed probe: empty input returns allow=false (fail-closed reason)" \
  bash -c "$(declare -f _opa_curl); CTX=$CTX; \
           out=\$(_opa_curl --data '{\"input\":{}}' --header 'Content-Type: application/json' \
             http://localhost:18181/v1/data/zta/authz/decision) && \
           [ \"\$(echo \"\$out\" | jq -r '.result.allow')\" = 'false' ] && \
           echo \"\$out\" | jq -re '.result.reason' \
             | grep -qxE 'default-deny|missing-token'"

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
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy logs -l app=opa --tail=200 --max-log-requests 4 \
                  | jq -c 'select(.decision_id != null)' 2>/dev/null | wc -l)\" -ge 1 ]"

check "OPA decision log has reason=device-tampered somewhere recent" \
  bash -c "kubectl --context $CTX -n zta-policy logs -l app=opa --tail=200 --max-log-requests 4 \
            | jq -r 'select(.result.headers[\"x-zta-decision-reason\"]) | .result.headers[\"x-zta-decision-reason\"]' \
            | grep -qx 'device-tampered'"

# Filter to Envoy ext_authz decisions only (path "zta/authz/result"). The
# port-forward probe in 02-verify.sh hits "zta/authz/decision" with an empty
# input, which legitimately has no method/posture/principal — including
# those entries would always fail this assertion.
check "every recent ext_authz decision has method, posture, principal in input" \
  bash -c "out=\$(kubectl --context $CTX -n zta-policy logs -l app=opa --tail=200 --max-log-requests 4 \
              | jq -c 'select(.decision_id and .path == \"zta/authz/result\") | {has_method: (.input.attributes.request.http.method != null), has_posture: (.input.attributes.request.http.headers[\"x-device-posture\"] != null), has_principal: (.input.attributes.source.principal != null)}' \
              | sort -u) && \
           [ \"\$out\" = '{\"has_method\":true,\"has_posture\":true,\"has_principal\":true}' ]"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 4 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

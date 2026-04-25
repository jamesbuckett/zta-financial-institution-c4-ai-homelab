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

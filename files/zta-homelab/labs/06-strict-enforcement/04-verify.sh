SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OPA's container has no shell or wget, so we can't `kubectl exec` HTTP
# probes inside it. Bridge to the cluster API via a single port-forward and
# re-use it across all four checks. /status (the diagnostic endpoint) lives
# on 8282 in the lab's deployment; /v1/policies on 8181.
kubectl --context docker-desktop -n zta-policy port-forward svc/opa 18181:8181 >/dev/null 2>&1 &
OPA_PF_8181=$!
kubectl --context docker-desktop -n zta-policy port-forward deploy/opa 18282:8282 >/dev/null 2>&1 &
OPA_PF_8282=$!
trap "kill $OPA_PF_8181 $OPA_PF_8282 2>/dev/null || true" EXIT
for _ in $(seq 1 20); do
  curl -s --max-time 1 http://localhost:18181/health >/dev/null 2>&1 && break
  sleep 0.5
done

# 1. The bundle is named 'zta' and has no errors.
# /v1/status (the OPA REST API on 8181) requires the `status` plugin to be
# enabled in opa-config. The diagnostic-addr endpoint /status (8282) is not
# what we want — that's a 404 on the diagnostic listener.
printf '\n== 1. OPA /v1/status: bundle name=zta, errors=null ==\n'
STATUS=$(curl -s http://localhost:18181/v1/status 2>/dev/null)
echo "$STATUS" | jq -r '.result.bundles.zta | "name=\(.name) errors=\(.errors)"'
# Expected: name=zta errors=null

# 2. last_successful_activation is recent (within 60 s).
printf '\n== 2. last_successful_activation is recent (<60s) ==\n'
ACT=$(echo "$STATUS" | jq -r '.result.bundles.zta.last_successful_activation')
NOW=$(date -u +%s)
ACT_TS=$(date -u -d "$ACT" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S%Z' "$ACT" +%s 2>/dev/null)
echo "act_age_s=$((NOW - ACT_TS))"
# Expected: act_age_s < 60

# 3. Make a request and confirm OPA still answers — proves the bundle ALSO
#    contains a working policy, not just a verifiable signature.
printf '\n== 3. trusted-posture request returns 200 ==\n'
# Refresh .env from Keycloak first (see refresh-env.sh for the why).
bash "$SCRIPT_DIR/../03-per-session/refresh-env.sh" || true
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

# 4. Watch /v1/policies — bundle policies are namespaced under <bundle-name>/.
# The bundle is named "zta" (from bundles.zta in opa-config), so the IDs
# look like "zta/policies/zta.authz.rego" — NOT the lab-4 inline path
# "/policies/zta.authz.rego". An earlier draft of this check expected
# "bundles/zta/", which never happens with OPA's bundle plugin.
printf '\n== 4. /v1/policies lists at least one path under the zta/ bundle ==\n'
curl -s http://localhost:18181/v1/policies | jq -r '.result[].id' | head -3
# Expected: paths beginning with "zta/" (e.g. zta/policies/zta.authz.rego)

kill $OPA_PF_8181 $OPA_PF_8282 2>/dev/null || true
trap - EXIT

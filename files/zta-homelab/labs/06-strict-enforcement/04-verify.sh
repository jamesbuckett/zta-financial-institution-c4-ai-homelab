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

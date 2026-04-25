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

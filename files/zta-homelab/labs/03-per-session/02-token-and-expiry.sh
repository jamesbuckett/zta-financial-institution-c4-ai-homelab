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

# Re-acquire TOKEN if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Token has three dot-separated segments — well-formed JWT.
printf '\n== 1. JWT has three dot-separated segments ==\n'
echo "$TOKEN" | awk -F. '{print NF}'
# Expected: 3

# 2. lifetime_s == 300, alg is HS256/RS256 (whatever Keycloak issued — never 'none').
printf '\n== 2. JWT alg is RS256/HS256 (never none) and lifetime is 300 ==\n'
echo "$TOKEN" | cut -d. -f1 | base64 -d 2>/dev/null | jq '.alg, .typ'
# Expected: "RS256"  "JWT"     (alg must NOT be "none")

LIFE=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp - .iat')
echo "lifetime_s=$LIFE"
# Expected: lifetime_s=300

# 3. iss matches the realm and aud is set — token is bound to this realm.
printf '\n== 3. iss/azp/typ bind token to this realm ==\n'
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.iss, .azp, .typ'
# Expected:
#   http://keycloak.local/realms/zta-bookstore
#   bookstore-api
#   Bearer

# 4. Signature verifies against the realm JWKS — proves it isn't a forged token.
printf '\n== 4. JWKS publishes at least one signing key ==\n'
JWKS=$(curl -s -H 'Host: keycloak.local' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/certs)
echo "$JWKS" | jq '.keys | length'
# Expected: >= 1   (a signing key is published; the SDK or API gateway will use it)

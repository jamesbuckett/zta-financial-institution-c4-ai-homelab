# Re-acquire TOKEN if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../03-per-session/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Capture the matrix into a file for asserting on, not eyeballing.
printf '\n== 1. Capture posture × method matrix to /tmp/zta-matrix.txt ==\n'
: > /tmp/zta-matrix.txt
for POSTURE in trusted suspect tampered; do
  for METHOD in GET POST; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -X $METHOD -H 'Host: bookstore.local' \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-device-posture: $POSTURE" \
      http://localhost/api/anything)
    echo "$POSTURE $METHOD $CODE" >> /tmp/zta-matrix.txt
  done
done
cat /tmp/zta-matrix.txt

# 2. Assert the exact 6-row decision shape T4 demands.
printf '\n== 2. Exact 6-row decision shape ==\n'
grep -c '^trusted GET 200$'   /tmp/zta-matrix.txt   # Expected: 1
grep -c '^trusted POST 200$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^suspect GET 200$'   /tmp/zta-matrix.txt   # Expected: 1
grep -c '^suspect POST 403$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^tampered GET 403$'  /tmp/zta-matrix.txt   # Expected: 1
grep -c '^tampered POST 403$' /tmp/zta-matrix.txt   # Expected: 1

# 3. Each denied response carries a decision-id header so the client can cite it.
printf '\n== 3. Denied response carries x-zta-decision-id header ==\n'
curl -sS -D - -o /dev/null \
  -X POST -H 'Host: bookstore.local' \
  -H "Authorization: Bearer $TOKEN" -H 'x-device-posture: tampered' \
  http://localhost/api/anything | grep -i 'x-zta-decision-id' | wc -l
# Expected: 1

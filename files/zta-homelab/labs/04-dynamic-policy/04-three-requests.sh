SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"

if [ ! -s "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Run Lab 3 first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

for POSTURE in trusted suspect tampered; do
  for METHOD in GET POST; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -X $METHOD \
      -H 'Host: bookstore.local' \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-device-posture: $POSTURE" \
      http://localhost/api/anything)
    printf 'posture=%-9s method=%-4s -> %s\n' "$POSTURE" "$METHOD" "$CODE"
  done
done

# Expected:
# posture=trusted   method=GET  -> 200
# posture=trusted   method=POST -> 200
# posture=suspect   method=GET  -> 200
# posture=suspect   method=POST -> 403
# posture=tampered  method=GET  -> 403
# posture=tampered  method=POST -> 403

export TOKEN

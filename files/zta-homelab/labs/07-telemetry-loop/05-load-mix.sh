#!/usr/bin/env bash
# Drive a 200-request load mix across (posture × method) so the dashboard
# panels have signal. Mostly trusted GETs with a trickle of suspect POSTs
# and the occasional tampered request — matches the source 5 flow.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

for i in $(seq 1 200); do
  POSTURES=(trusted trusted trusted trusted suspect suspect tampered)
  METHODS=(GET GET GET GET POST)
  P=${POSTURES[$((RANDOM % 7))]}
  M=${METHODS[$((RANDOM % 5))]}
  curl -s -o /dev/null -X $M \
    -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
    -H "x-device-posture: $P" \
    http://localhost/api/anything &
  if [ $((i % 20)) -eq 0 ]; then wait; fi
done
wait
echo "load mix complete"

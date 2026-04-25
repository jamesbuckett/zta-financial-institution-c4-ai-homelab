#!/usr/bin/env bash
# Close the loop: posture=tampered -> 403 deny, operator clears annotation,
# pod is force-deleted (skipping reconciler wait), new pod resolves the env
# var to 'trusted', second request returns 200.
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

# Round 1 — denied:
curl -s -o /dev/null -w 'round1=%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: round1=403

# Operator remediates — manually clear the tampered annotation:
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1)
kubectl --context docker-desktop -n bookstore-api annotate --overwrite $POD zta.posture=trusted
# Wait for reconciler (up to ~60 s) or force a bounce:
kubectl --context docker-desktop -n bookstore-api delete $POD
kubectl --context docker-desktop -n bookstore-api rollout status deploy/api

# Round 2 — allowed:
curl -s -o /dev/null -w 'round2=%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: round2=200

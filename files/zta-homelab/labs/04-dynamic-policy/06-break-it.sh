#!/usr/bin/env bash
# Break-it exercise (Lab 4): change the Rego default for missing posture from
# "unknown" to "trusted" and observe that requests omitting the posture header
# are now ALLOWED — fail-open. Tenet 4 prohibits this.
#
# Run manually: bash 06-break-it.sh
# Repair:       restore the original 01-zta.authz.rego (git checkout -- 01-zta.authz.rego)
#               and re-run 00-dynamic-policy-install.sh's step 02 to redeploy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"

if [ ! -s "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Run Lab 3 first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Patch the Rego in place (else := "unknown" -> else := "trusted") and rebuild
# the ConfigMap from the patched file. The user must restore by hand.
TMP_REGO=$(mktemp)
trap 'rm -f "$TMP_REGO"' EXIT
sed 's/} else := "unknown"/} else := "trusted"   # BAD/' \
  "$SCRIPT_DIR/01-zta.authz.rego" > "$TMP_REGO"
diff "$SCRIPT_DIR/01-zta.authz.rego" "$TMP_REGO" || true

kubectl --context docker-desktop -n zta-policy create configmap opa-policy \
  --from-file=zta.authz.rego="$TMP_REGO" --dry-run=client -o yaml \
  | kubectl --context docker-desktop apply -f -
kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa
kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s

# Acquire a fresh token.
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

# Attack: drop the posture header entirely.
echo "Attack: POST with no x-device-posture header (BAD policy treats missing as trusted)..."
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/anything
# Expected (bad): 200  — fail-open on missing signal
echo "(Repair: restore 01-zta.authz.rego from git and re-run step 02 of the orchestrator.)"

trap 'kill $PF_PID 2>/dev/null' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Telemetry resource exists at mesh root with otel-tempo provider and 100% sampling.
printf '\n== 1. Telemetry mesh-default has otel-tempo at 100%% sampling ==\n'
kubectl --context docker-desktop -n istio-system get telemetry mesh-default \
  -o jsonpath='{.spec.tracing[0].providers[0].name}/{.spec.tracing[0].randomSamplingPercentage}{"\n"}'
# Expected: otel-tempo/100

# 2. Mesh config registers BOTH extension providers (opa-ext-authz preserved + otel-tempo added).
printf '\n== 2. Mesh config has BOTH opa-ext-authz and otel-tempo ==\n'
kubectl --context docker-desktop -n istio-system get cm istio \
  -o jsonpath='{.data.mesh}' \
  | yq -r '.extensionProviders[].name' | sort
# Expected:
#   opa-ext-authz
#   otel-tempo

# 3. Make a request and confirm the api sidecar emits an OTel trace export.
printf '\n== 3. Tempo records traces from istio-ingressgateway ==\n'
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
curl -s -o /dev/null -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  -H 'x-device-posture: trusted' http://localhost/api/headers
sleep 5

kubectl --context docker-desktop -n zta-observability port-forward svc/tempo 3200:3200 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:3200/api/search?tags=service.name=istio-ingressgateway&limit=5' \
  | jq '.traces | length'
# Expected: >= 1
kill $PF_PID 2>/dev/null
unset PF_PID

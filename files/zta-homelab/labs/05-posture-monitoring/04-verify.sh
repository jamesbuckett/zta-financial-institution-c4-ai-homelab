# 1. EnvoyFilter exists in bookstore-api and inserts a Lua HTTP filter.
printf '\n== 1. EnvoyFilter project-posture-header inserts Lua HTTP filter ==\n'
kubectl --context docker-desktop -n bookstore-api get envoyfilter project-posture-header \
  -o jsonpath='{.spec.configPatches[0].patch.value.name}{"\n"}'
# Expected: envoy.filters.http.lua

# 2. The Lua source actually contains the x-device-posture insertion logic.
printf '\n== 2. Lua source contains x-device-posture ==\n'
kubectl --context docker-desktop -n bookstore-api get envoyfilter project-posture-header \
  -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.inlineCode}' \
  | grep -c 'x-device-posture'
# Expected: 1

# 3. The api Deployment exposes ZTA_POD_POSTURE via downward API.
printf "\n== 3. api Deployment exposes ZTA_POD_POSTURE from metadata.annotations['zta.posture'] ==\n"
kubectl --context docker-desktop -n bookstore-api get deploy api \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="httpbin")].env}' \
  | jq -r '.[] | select(.name=="ZTA_POD_POSTURE") | .valueFrom.fieldRef.fieldPath'
# Expected: metadata.annotations['zta.posture']

# 4. Live request from the frontend now carries the header even when the caller did not.
# Lab 4's OPA ext_authz is in the chain, so the request needs a valid token
# (otherwise allow rules don't match and the request 403s before the upstream
# can echo the injected X-Device-Posture back). We deliberately do NOT send
# x-device-posture in the wget — the Lua filter must inject it from the pod
# annotation/env.
printf '\n== 4. frontend->api response carries X-Device-Posture (not "missing") ==\n'
SCRIPT_DIR_LAB05="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_LAB05/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)
FRONTEND=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1)
kubectl --context docker-desktop -n bookstore-frontend exec $FRONTEND -c nginx -- \
  wget -qO- --header="Authorization: Bearer $TOKEN" \
  'http://api.bookstore-api.svc.cluster.local/headers' \
  | jq -r '.headers["X-Device-Posture"] // "missing"'
# Expected: a string ('trusted' by default, or whatever the current pod
#           annotation says) — must NOT be "missing"

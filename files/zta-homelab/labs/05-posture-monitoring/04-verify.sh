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
printf '\n== 4. frontend->api response carries X-Device-Posture (not "missing") ==\n'
FRONTEND=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1)
kubectl --context docker-desktop -n bookstore-frontend exec $FRONTEND -c nginx -- \
  wget -qO- 'http://api.bookstore-api.svc.cluster.local/headers' \
  | jq -r '.headers["X-Device-Posture"] // "missing"'
# Expected: a string ('trusted' if no annotation set yet, or whatever the
#           current pod annotation says) — must NOT be "missing"

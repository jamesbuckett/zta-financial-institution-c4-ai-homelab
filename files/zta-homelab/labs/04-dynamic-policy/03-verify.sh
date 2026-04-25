# 1. Mesh config publishes the extension provider.
printf '\n== 1. mesh config registers opa-ext-authz extension provider ==\n'
kubectl --context docker-desktop -n istio-system get configmap istio \
  -o jsonpath='{.data.mesh}' | grep -A2 extensionProviders | grep -c opa-ext-authz
# Expected: 1

# 2. EnvoyFilter is registered in istio-system.
printf '\n== 2. EnvoyFilter ext-authz-opa applies to CLUSTER ==\n'
kubectl --context docker-desktop -n istio-system get envoyfilter ext-authz-opa \
  -o jsonpath='{.spec.configPatches[0].applyTo}{"\n"}'
# Expected: CLUSTER

# 3. CUSTOM AuthorizationPolicy on the api uses provider opa-ext-authz.
printf '\n== 3. AuthorizationPolicy ext-authz-opa is CUSTOM/opa-ext-authz ==\n'
kubectl --context docker-desktop -n bookstore-api get authorizationpolicy ext-authz-opa \
  -o jsonpath='{.spec.action}/{.spec.provider.name}{"\n"}'
# Expected: CUSTOM/opa-ext-authz

# 4. The api sidecar's listener actually contains the ext_authz filter.
printf '\n== 4. api sidecar inbound listener contains ext_authz filter ==\n'
istioctl --context docker-desktop proxy-config listener \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  --port 15006 -o json \
  | jq -r '..|.name? // empty' | grep -c 'envoy\.filters\.http\.ext_authz'
# Expected: >= 1

# 5. The OPA gRPC port is reachable from the api sidecar.
printf '\n== 5. OPA gRPC port (9191) reachable from api sidecar ==\n'
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c istio-proxy -- /bin/sh -c 'echo > /dev/tcp/opa.zta-policy.svc.cluster.local/9191 && echo OK'
# Expected: OK

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

# Filter for Running pods only — `kubectl rollout status` returns when the
# new ReplicaSet is available, but old replicas may linger in Succeeded or
# Terminating for a few seconds while the istio-proxy drains. Picking the
# first matching pod without filtering can grab one of those, then exec
# fails with "pod not found" or "completed pod".
api_running_pod() {
  kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
    --field-selector=status.phase=Running -o name | head -1
}

# 4. The api sidecar's listener actually contains the ext_authz filter.
printf '\n== 4. api sidecar inbound listener contains ext_authz filter ==\n'
istioctl --context docker-desktop proxy-config listener \
  $(api_running_pod | cut -d/ -f2).bookstore-api \
  --port 15006 -o json \
  | jq -r '..|.name? // empty' | grep -c 'envoy\.filters\.http\.ext_authz'
# Expected: >= 1

# 5. The OPA gRPC port is reachable from the api sidecar.
# /bin/sh in the istio-proxy container is dash (no /dev/tcp builtin); use nc
# from the same container, which is shipped in proxyv2 and works portably.
printf '\n== 5. OPA gRPC port (9191) reachable from api sidecar ==\n'
kubectl --context docker-desktop -n bookstore-api exec \
  $(api_running_pod) \
  -c istio-proxy -- nc -z -w 3 opa.zta-policy.svc.cluster.local 9191 \
  && echo OK
# Expected: OK

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

# Pick a live, fully-Ready api pod. `kubectl rollout status` returns as soon
# as the new ReplicaSet is Available, but old pods from the previous RS are
# still being terminated in the background. Those old pods stay in
# status.phase=Running for the whole terminationGracePeriodSeconds window
# (phase only flips when containers actually exit), so a phase-only filter
# can return a terminating pod. On that pod the istio-proxy native sidecar
# (init container with restartPolicy=Always) has already been gc'd by the
# kubelet, so `kubectl exec -c istio-proxy` fails with `container not found`
# and `istioctl proxy-config` gets EOF on the admin port-forward (then jq
# parse-errors on the empty body).
#
# Exclude pods with a deletionTimestamp set (i.e. terminating) and require
# all main containers to be Ready, then take the first match.
api_running_pod() {
  kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o json \
    | jq -r '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select((.status.containerStatuses // []) | length > 0)
        | select([.status.containerStatuses[].ready] | all)
        | "pod/" + .metadata.name
      ' | head -1
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

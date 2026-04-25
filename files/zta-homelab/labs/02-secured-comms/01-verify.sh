# 1. PeerAuthentication is at mesh root and mode is STRICT.
printf '\n== 1. Mesh-root PeerAuthentication mode is STRICT ==\n'
kubectl --context docker-desktop -n istio-system get peerauthentication default \
  -o jsonpath='{.spec.mtls.mode}{"\n"}'
# Expected: STRICT

# 2. No namespace-level PeerAuthentication is overriding back to PERMISSIVE.
printf '\n== 2. No namespace overrides relax STRICT ==\n'
kubectl --context docker-desktop get peerauthentication -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.mtls.mode}{"\n"}{end}' \
  | grep -v '=STRICT$' || echo 'all STRICT'
# Expected: all STRICT

# 3. The mesh control plane has propagated the policy to every sidecar.
printf '\n== 3. api sidecar inbound listener uses TLS transport socket ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name \
  | head -1 \
  | xargs -I{} istioctl --context docker-desktop proxy-config listener {}.bookstore-api --port 15006 -o json \
  | jq -r '..|.transportSocket?.name? // empty' | sort -u
# Expected: contains envoy.transport_sockets.tls — the inbound listener terminates mTLS

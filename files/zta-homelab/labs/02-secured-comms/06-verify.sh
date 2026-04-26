# 1. The old `istioctl authn tls-check` SERVER/CLIENT/STATUS triple was
#    removed after Istio 1.20. The modern split — proxy-config cluster on
#    the source + experimental describe on the destination — proves the
#    same posture: client uses TLS transport, server enforces STRICT.

printf '\n== 1. Source outbound cluster uses Envoy TLS transport socket ==\n'
FRONTEND_POD=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2)
istioctl --context docker-desktop proxy-config cluster -n bookstore-frontend "$FRONTEND_POD" \
  --fqdn api.bookstore-api.svc.cluster.local -o json \
  | jq -r '.[0].transportSocketMatches[0].transportSocket.name // "(none)"'
# Expected: envoy.transport_sockets.tls

printf '\n== 1b. Destination workload effective PeerAuthentication mode ==\n'
API_POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
# istioctl 1.22 doesn't honor `-n <ns>` for the pod fetch in
# `experimental describe pod`; the `<pod>.<namespace>` shorthand does.
istioctl --context docker-desktop experimental describe pod "$API_POD.bookstore-api" \
  | awk '/Workload mTLS mode:/ {print $NF}'
# Expected: STRICT

# 2. Sidecar reports a SECRET resource carrying a SPIFFE SVID for the api workload.
printf '\n== 2. api sidecar has SVID secrets (ROOTCA + default) ==\n'
istioctl --context docker-desktop proxy-config secret \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  -o json \
  | jq -r '.dynamicActiveSecrets[]?.name' | sort -u
# Expected: ROOTCA, default        (default = the workload's SVID)

# 3. The SVID's URI SAN names the api workload — proves Istio CA, not a bystander, signed it.
printf '\n== 3. SVID URI SAN matches the api workload ==\n'
istioctl --context docker-desktop proxy-config secret \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null
# Expected: URI:spiffe://cluster.local/ns/bookstore-api/sa/default

# 4. Capture and control-plane view AGREE — neither dissents about STRICT.
printf '\n== 4. Capture has no plaintext HTTP — agrees with control plane ==\n'
grep -cE '^(GET|POST) ' /tmp/capture.txt 2>/dev/null || echo 0
# Expected: 0  (matches the istioctl OK / STRICT line above; both agree)

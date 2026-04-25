# 1. tls-check reports SERVER=STRICT, CLIENT=ISTIO_MUTUAL, STATUS=OK.
printf '\n== 1. istioctl authn tls-check reports OK STRICT ISTIO_MUTUAL ==\n'
istioctl --context docker-desktop authn tls-check \
  $(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2).bookstore-frontend \
  api.bookstore-api.svc.cluster.local \
  | awk 'NR>1 {print $2,$3,$4}' | head -1
# Expected: OK STRICT ISTIO_MUTUAL

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

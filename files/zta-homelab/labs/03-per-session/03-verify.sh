SS=$(kubectl --context docker-desktop -n spire get pod -l app=spire-server -o name | head -1)

# 1. Entry exists for the bookstore-api workload with both selectors.
printf '\n== 1. SPIRE entry exists for bookstore-api workload ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default
# Expected: one entry with selectors k8s:ns:bookstore-api and k8s:sa:default

# 2. SVID TTL is 300 s (per-session is "short-lived", not "default 1h").
printf '\n== 2. X509-SVID TTL is 300 seconds ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
  | awk '/X509-SVID TTL/ {print $NF; exit}'
# Expected: 300

# 3. SPIRE agent reports the entry has been distributed to a node.
printf '\n== 3. SPIRE agent registered on docker-desktop node ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server agent list \
  | grep -c 'docker-desktop'
# Expected: >= 1   (one agent per node; we have one node)

# 4. No duplicate entries — exactly one canonical SPIFFE ID for this workload.
printf '\n== 4. Exactly one SPIRE entry for this SPIFFE ID ==\n'
kubectl --context docker-desktop -n spire exec -i $SS -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
  | grep -c '^Entry ID'
# Expected: 1

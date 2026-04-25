# 1. The plaintext call exits non-zero with curl code 52 (Empty reply).
printf '\n== 1. Plaintext curl from out-of-mesh pod fails (expected exit 52) ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- \
  bash -c "curl -sS --max-time 5 http://api.bookstore-api.svc.cluster.local/headers; echo EXIT=\$?"
# Expected: a curl error message (Empty reply / Recv failure) and EXIT=52
#           (NOT EXIT=0 — that would mean STRICT mTLS is not enforced)

# 2. TCP reaches the sidecar but is then closed without an HTTP body —
#    proves the sidecar accepted the connection then refused the plaintext.
printf '\n== 2. Raw TCP connect succeeds but no HTTP/1.1 response is returned ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- \
  bash -c "echo -e 'GET /headers HTTP/1.1\r\nHost: api.bookstore-api.svc.cluster.local\r\n\r\n' \
           | timeout 4 nc -v api.bookstore-api.svc.cluster.local 80; echo EXIT=\$?"
# Expected: 'open' or 'succeeded' on connect, then EOF / no HTTP/1.1 response.
#           No "HTTP/1.1 200" or "HTTP/1.1 4xx" line — the sidecar dropped before HTTP.

# 3. Istio access log on the api side shows a connection-level reset, not an HTTP 4xx.
printf '\n== 3. api sidecar access log shows connection-level termination ==\n'
kubectl --context docker-desktop -n bookstore-api logs \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c istio-proxy --tail=5 | grep -E 'response_code_details|connection_termination' || true
# Expected: lines containing 'connection_termination_details' or response code 0
#           — STRICT mTLS terminated before any HTTP layer existed.

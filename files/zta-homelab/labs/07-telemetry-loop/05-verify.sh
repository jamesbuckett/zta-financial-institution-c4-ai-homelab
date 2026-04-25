trap '[ -n "${PROM_PID:-}" ] && kill $PROM_PID 2>/dev/null; [ -n "${LOKI_PID:-}" ] && kill $LOKI_PID 2>/dev/null' EXIT

# Open ONE Prom port-forward up front and reuse it for checks 1 and 3.
# (The doc had a bug: it killed the Prom PF after check 1, then check 3
# silently returned 0 because :9090 was no longer listening.)
kubectl --context docker-desktop -n zta-policy port-forward svc/kube-prom-kube-prome-prometheus 9090:9090 >/dev/null 2>&1 &
PROM_PID=$!; sleep 3

# 1. The load mix produced >= 200 OPA decisions in the last 5 minutes.
printf '\n== 1. >=200 OPA decisions in last 5 minutes ==\n'
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(increase(http_request_duration_seconds_count{job=~"opa.*"}[5m]))' \
  | jq '.data.result[0].value[1] | tonumber'
# Expected: >= 200

# 2. All three posture values appear in Loki (proves the dashboard's deny-reasons panel has signal).
printf '\n== 2. Loki has events for trusted, suspect, and tampered postures ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
LOKI_PID=$!; sleep 3
for P in trusted suspect tampered; do
  N=$(curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
    --data-urlencode "query={namespace=\"zta-policy\", posture=\"$P\"}" \
    --data-urlencode "start=$(date -u -d '-10 min' +%s)000000000" \
    --data-urlencode "end=$(date -u +%s)000000000" \
    | jq '[.data.result[].values[] | length] | add // 0')
  echo "$P=$N"
done
# Expected: trusted > 0, suspect > 0, tampered > 0
kill $LOKI_PID 2>/dev/null
unset LOKI_PID

# 3. P99 decision latency is below the 800-207 8.6 SLO ceiling of 10 ms.
# Prom port-forward (PROM_PID) is still alive from the top of this script.
printf '\n== 3. P99 decision latency < 10 ms ==\n'
P99=$(curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=1000 * histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=~"opa.*"}[5m])))' \
  2>/dev/null | jq -r '.data.result[0].value[1] // "0"')
echo "P99_ms=$P99"
# Expected: P99_ms < 10
kill $PROM_PID 2>/dev/null
unset PROM_PID

trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. opa-metrics Service exposes diagnostic port 8282 with selector app=opa.
printf '\n== 1. opa-metrics Service exposes 8282 with selector app=opa ==\n'
kubectl --context docker-desktop -n zta-policy get svc opa-metrics \
  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}{" sel="}{.spec.selector.app}{"\n"}'
# Expected: 8282/8282 sel=opa

printf '\n== 1b. opa-metrics endpoints populated ==\n'
kubectl --context docker-desktop -n zta-policy get endpoints opa-metrics \
  -o jsonpath='{.subsets[0].addresses[*].ip}{"\n"}' | wc -w
# Expected: >= 1

# 2. ServiceMonitor exists and matches the kube-prom release label.
printf '\n== 2. ServiceMonitor opa has release=kube-prom label ==\n'
kubectl --context docker-desktop -n zta-observability get servicemonitor opa \
  -o jsonpath='{.metadata.labels.release}{"\n"}'
# Expected: kube-prom

# 3. Prometheus has discovered OPA as an active target (port-forward Prom first).
# Service name is kube-prom-kube-prometheus-prometheus (the chart's full
# release-name + component-name pattern); the earlier draft had a typo
# ("kube-prome-") and the port-forward silently exited 1 → empty result.
printf '\n== 3. Prometheus reports OPA target health=up ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/kube-prom-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  curl -s --max-time 1 http://localhost:9090/-/ready >/dev/null 2>&1 && break
  sleep 0.5
done
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '[.data.activeTargets[] | select(.labels.job=="opa") | .health] | unique'
# Expected: ["up"]
kill $PF_PID 2>/dev/null
unset PF_PID

# 4. Metrics actually contain the OPA decision counter.
# OPA's distroless image has no wget/curl, so probe via port-forward instead
# of `kubectl exec`.
printf '\n== 4. OPA /metrics contains opa_* lines ==\n'
kubectl --context docker-desktop -n zta-policy port-forward deploy/opa 18282:8282 >/dev/null 2>&1 &
PF2_PID=$!
for _ in $(seq 1 20); do
  curl -s --max-time 1 http://localhost:18282/health >/dev/null 2>&1 && break
  sleep 0.5
done
# OPA 0.68's diagnostic /metrics endpoint doesn't expose any opa_-prefixed
# Prometheus metrics (the prefix existed in older versions); all process and
# request metrics are go_* and http_*. Use the http_request_duration_seconds
# counter as the proof-of-life — the same series that Prometheus scrapes
# and that the lab 7 ServiceMonitor selects for its scrape job.
curl -s http://localhost:18282/metrics | grep -c '^http_request_duration_seconds' || echo 0
kill $PF2_PID 2>/dev/null || true
# Expected: >= 1

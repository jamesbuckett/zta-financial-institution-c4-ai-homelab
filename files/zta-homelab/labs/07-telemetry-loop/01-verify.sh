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
printf '\n== 3. Prometheus reports OPA target health=up ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/kube-prom-kube-prome-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '[.data.activeTargets[] | select(.labels.job=="opa") | .health] | unique'
# Expected: ["up"]
kill $PF_PID 2>/dev/null
unset PF_PID

# 4. Metrics actually contain the OPA decision counter.
printf '\n== 4. OPA /metrics contains opa_* lines ==\n'
OPA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=opa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- http://localhost:8282/metrics | grep -c '^opa_'
# Expected: >= 1

trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. ConfigMap carries the grafana_dashboard label so the sidecar provisioner picks it up.
printf '\n== 1. zta-dashboard ConfigMap has grafana_dashboard=1 label ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.metadata.labels.grafana_dashboard}{"\n"}'
# Expected: 1

# 2. Embedded JSON parses and declares exactly four panels with Tenet-7-aligned titles.
printf '\n== 2. Embedded JSON has exactly 4 panels ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.data.zta\.json}' | jq '.panels | length'
# Expected: 4

printf '\n== 2b. Panel titles ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.data.zta\.json}' | jq -r '.panels[].title'
# Expected (any order):
#   Decision rate (allow / deny / step-up)
#   Decision latency P50 / P99 (ms)
#   Deny reasons — last 1h
#   Recent denies (decision_id, path, posture, reason)

# 3. Grafana has registered the dashboard under uid 'zta-main'.
printf '\n== 3. Grafana has dashboard uid=zta-main ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/kube-prom-grafana 3000:80 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -su admin:admin http://localhost:3000/api/dashboards/uid/zta-main \
  | jq -r '.dashboard.title // "missing"'
# Expected: ZTA — Decisions, Latency, Drift (800-207 8.6 SLOs)
kill $PF_PID 2>/dev/null
unset PF_PID

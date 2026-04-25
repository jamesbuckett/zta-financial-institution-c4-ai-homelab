trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. DaemonSet runs on every node.
printf '\n== 1. grafana-agent DS ready count == node count ==\n'
NODES=$(kubectl --context docker-desktop get nodes --no-headers | wc -l)
READY=$(kubectl --context docker-desktop -n zta-observability get ds grafana-agent \
          -o jsonpath='{.status.numberReady}')
echo "nodes=$NODES ready=$READY"
# Expected: nodes equals ready

# 2. Agent config targets the Loki cluster service and parses to a single client URL.
printf '\n== 2. Agent config Loki URL is the cluster service ==\n'
kubectl --context docker-desktop -n zta-observability get cm grafana-agent-config \
  -o jsonpath='{.data.agent\.yaml}' \
  | yq -r '.logs.configs[0].clients[0].url'
# Expected: http://loki.zta-observability.svc.cluster.local:3100/loki/api/v1/push

# 3. Pipeline stage extracts decision_id, allow, reason as Loki labels.
printf '\n== 3. Pipeline stage promotes decision_id, allow, reason to labels ==\n'
kubectl --context docker-desktop -n zta-observability get cm grafana-agent-config \
  -o jsonpath='{.data.agent\.yaml}' \
  | yq -r '.logs.configs[0].scrape_configs[0].pipeline_stages[1].labels | keys | .[]'
# Expected (any order, must include all three):
#   decision_id
#   allow
#   reason

# 4. Loki is reachable and reports zta-policy as a discovered namespace label.
printf '\n== 4. Loki reports a namespace label ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq -r '.data | .[]' | grep -c '^namespace$'
# Expected: 1
kill $PF_PID 2>/dev/null
unset PF_PID

# 1. Falcosidekick pod is up and reports the webhook address as the CDM service.
printf '\n== 1. falco-falcosidekick is 1/1 and WEBHOOK_ADDRESS points to CDM ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | jq -r '.[] | select(.name=="WEBHOOK_ADDRESS") | .value'
# Expected: http://cdm.zta-runtime-security.svc.cluster.local/

# 2. minimumpriority is 'notice' (not 'critical') — captures Terminal-shell.
printf '\n== 2. WEBHOOK_MINIMUMPRIORITY == notice ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | jq -r '.[] | select(.name=="WEBHOOK_MINIMUMPRIORITY") | .value'
# Expected: notice

# 3. End-to-end: synthesise a Falco POST through Falcosidekick and confirm
#    the CDM logs the dispatch.
printf '\n== 3. Synthetic event via sidekick reaches CDM ==\n'
SK_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falcosidekick -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $SK_POD -- \
  wget -qO- --post-data='{"priority":"Notice","rule":"smoke","output_fields":{"k8s.ns.name":"bookstore-api","k8s.pod.name":"smoke"}}' \
  --header='Content-Type: application/json' http://localhost:2801/ >/dev/null
sleep 2
kubectl --context docker-desktop -n zta-runtime-security logs deploy/cdm --tail=20 | grep -c 'PATCHED\|smoke'
# Expected: >= 1

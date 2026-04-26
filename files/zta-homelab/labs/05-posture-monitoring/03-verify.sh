# 1. Falcosidekick Deployment is fully ready and WEBHOOK_ADDRESS points to CDM.
# The Helm chart defaults to 2 replicas, so `1/1` is wrong; assert
# readyReplicas == replicas instead. WEBHOOK_* settings come in via
# `envFrom: secretRef: falco-falcosidekick`, so read the secret.
printf '\n== 1. falcosidekick rollout is fully ready and WEBHOOK_ADDRESS points to CDM ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: N/N (e.g. 2/2)

kubectl --context docker-desktop -n zta-runtime-security get secret falco-falcosidekick \
  -o jsonpath='{.data.WEBHOOK_ADDRESS}' | base64 -d
echo
# Expected: http://cdm.zta-runtime-security.svc.cluster.local/

# 2. minimumpriority is 'notice' (not 'critical') — captures Terminal-shell.
printf '\n== 2. WEBHOOK_MINIMUMPRIORITY == notice ==\n'
kubectl --context docker-desktop -n zta-runtime-security get secret falco-falcosidekick \
  -o jsonpath='{.data.WEBHOOK_MINIMUMPRIORITY}' | base64 -d
echo
# Expected: notice

# 3. End-to-end: synthesise a Falco POST through Falcosidekick and confirm
#    the CDM logs the dispatch.
# Falcosidekick rejects events missing required Falco fields with HTTP 400,
# so include priority/rule/output/time/source/output_fields.
# 127.0.0.1 (not 'localhost') because busybox-wget in this image resolves IPv6
# first and sidekick binds IPv4 only.
printf '\n== 3. Synthetic event via sidekick reaches CDM ==\n'
SK_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falcosidekick -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $SK_POD -- \
  wget -qO- --post-data='{"priority":"Notice","rule":"smoke","output":"smoke alert","time":"2026-04-26T04:10:00Z","source":"syscall","output_fields":{"k8s.ns.name":"bookstore-api","k8s.pod.name":"smoke"}}' \
  --header='Content-Type: application/json' http://127.0.0.1:2801/ >/dev/null
sleep 2
kubectl --context docker-desktop -n zta-runtime-security logs deploy/cdm --tail=20 | grep -c 'PATCHED\|smoke'
# Expected: >= 1

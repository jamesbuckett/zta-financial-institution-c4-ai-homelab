# 1. Deployment is Available with 1/1 replicas.
printf '\n== 1. svid-watcher Deployment is 1/1 ready ==\n'
kubectl --context docker-desktop -n bookstore-api get deploy svid-watcher \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

# 2. Pod has TWO containers (helper + observer) — no Istio sidecar attached
#    because zta-lab-debug-style injection isn't disabled here, so we expect
#    THREE containers if Lab 2 is still active. Either is acceptable; the
#    helper and observer must both be present.
printf '\n== 2. watcher and observer containers are present ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=svid-watcher \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# Expected: contains 'watcher' and 'observer'

# 3. svid-helper ConfigMap is mounted and contains the agent_address path.
printf '\n== 3. svid-helper ConfigMap contains agent_address ==\n'
kubectl --context docker-desktop -n bookstore-api get configmap svid-helper \
  -o jsonpath='{.data.helper\.conf}' | grep -c agent_address
# Expected: 1

# 4. The SPIRE agent's hostPath socket is reachable from the pod
#    (an SVID file should appear within a few seconds of pod start).
printf '\n== 4. /svid/svid.pem appears in the watcher pod ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=svid-watcher -o name | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do
  if kubectl --context docker-desktop -n bookstore-api exec $POD -c observer -- \
       test -f /svid/svid.pem 2>/dev/null; then echo "svid present"; break; fi
  sleep 3
done
# Expected: svid present

# 1. CronJob exists with the every-minute schedule.
printf '\n== 1. posture-reconciler CronJob schedule == */1 * * * * ==\n'
kubectl --context docker-desktop -n zta-runtime-security get cronjob posture-reconciler \
  -o jsonpath='{.spec.schedule}{"\n"}'
# Expected: */1 * * * *

# 2. CronJob runs as the cdm ServiceAccount (RBAC-bound, not cluster-admin).
printf '\n== 2. CronJob runs as serviceAccount cdm ==\n'
kubectl --context docker-desktop -n zta-runtime-security get cronjob posture-reconciler \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}{"\n"}'
# Expected: cdm

# 3. End-to-end smoke: annotate the api pod & wait for reconcile to fire,
#    then confirm the env var on the new pod matches the annotation.
printf '\n== 3. End-to-end: annotate api pod and wait <=75s for bounce ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
kubectl --context docker-desktop -n bookstore-api annotate --overwrite pod/$POD zta.posture=suspect
# Wait up to ~75 s for the next CronJob tick + a fresh pod.
for i in $(seq 1 25); do
  NEW=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
  if [ "$NEW" != "$POD" ]; then
    sleep 5
    NEWANN=$(kubectl --context docker-desktop -n bookstore-api get pod $NEW -o jsonpath='{.metadata.annotations.zta\.posture}')
    NEWENV=$(kubectl --context docker-desktop -n bookstore-api get pod $NEW -o jsonpath='{.spec.containers[?(@.name=="httpbin")].env[?(@.name=="ZTA_POD_POSTURE")].value}')
    echo "ann=$NEWANN env=$NEWENV"
    break
  fi
  sleep 3
done
# Expected (after at most ~75 s): ann=suspect env=metadata.annotations['zta.posture']
#                                 (the env var spec is preserved; new pod resolves it.)

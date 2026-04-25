# 1. ConstraintTemplate is Established — Gatekeeper accepted the Rego.
kubectl --context docker-desktop get constrainttemplate k8srequiredztalabels \
  -o jsonpath='{.status.byPod[*].observedGeneration}{"\n"}{range .status.byPod[*]}{.id}{"="}{.operations}{"\n"}{end}'
# Expected: a generation number, then one row per Gatekeeper pod listing the
#           operations it has registered (audit, mutation-status, webhook).

# 2. The constraint CRD is registered cluster-wide.
kubectl --context docker-desktop get crd k8srequiredztalabels.constraints.gatekeeper.sh \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}{"\n"}'
# Expected: True

# 3. The constraint object exists with the three required labels in spec.parameters.
kubectl --context docker-desktop get k8srequiredztalabels bookstore-resources-labelled \
  -o jsonpath='{.spec.parameters.required}{"\n"}'
# Expected: ["zta.resource","zta.data-class","zta.owner"]

# 4. Failure policy is Fail (fail-closed) — required for ZTA posture.
kubectl --context docker-desktop get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  -o jsonpath='{.webhooks[?(@.name=="validation.gatekeeper.sh")].failurePolicy}{"\n"}'
# Expected: Fail

# 5. Audit reports zero existing violations — Step 02 back-fill worked.
kubectl --context docker-desktop get k8srequiredztalabels bookstore-resources-labelled \
  -o jsonpath='{.status.totalViolations}{"\n"}'
# Expected: 0


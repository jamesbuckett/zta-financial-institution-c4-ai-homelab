# First apply installs the ConstraintTemplate, which registers the
# K8sRequiredZtaLabels CRD. The constraint itself will fail on this first
# pass with "no matches for kind K8sRequiredZtaLabels" — that is expected.
kubectl --context docker-desktop apply -f gatekeeper-required-labels.yaml || true
# Expected on first pass:
#   constrainttemplate.templates.gatekeeper.sh/k8srequiredztalabels created
#   error: resource mapping not found for ... K8sRequiredZtaLabels ... ensure CRDs are installed first

# Wait for Gatekeeper to register the constraint CRD.
kubectl --context docker-desktop wait --for=condition=established \
  crd/k8srequiredztalabels.constraints.gatekeeper.sh --timeout=60s

# Re-apply so the constraint object is now created against the established CRD.
kubectl --context docker-desktop apply -f gatekeeper-required-labels.yaml
# Expected: constrainttemplate.templates.gatekeeper.sh/k8srequiredztalabels unchanged
#           k8srequiredztalabels.constraints.gatekeeper.sh/bookstore-resources-labelled created


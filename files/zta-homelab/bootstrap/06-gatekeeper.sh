#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

# OPA Gatekeeper — admission-time policy PEP
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update

# Pre-create + pre-label gatekeeper-system so gatekeeper's own validating
# webhook skips this namespace. Otherwise the chart's labelNamespace
# post-install Job races webhook readiness — its kubectl-label call goes
# through the API server, which calls the webhook before all endpoints are
# accepting TLS. failurePolicy=Fail (set below) turns that transient race
# into a hard reject.
kubectl --context $CTX create namespace gatekeeper-system \
  --dry-run=client -o yaml | kubectl --context $CTX apply -f -
kubectl --context $CTX label namespace gatekeeper-system \
  admission.gatekeeper.sh/ignore=no-self-managing --overwrite

# ZTA posture is fail-closed: if Gatekeeper cannot evaluate a request, reject it
# instead of admitting it. This flips the validation.gatekeeper.sh webhook's
# failurePolicy from the chart default (Ignore) to Fail.
helm --kube-context $CTX upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --version 3.17.1 --wait \
  --set validatingWebhookFailurePolicy=Fail \
  --set postInstall.labelNamespace.enabled=false \
  --set postInstall.probeWebhook.enabled=false

echo "Gatekeeper installed."


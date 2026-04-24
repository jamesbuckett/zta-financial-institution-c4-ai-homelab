#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

# OPA Gatekeeper — admission-time policy PEP
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update
# ZTA posture is fail-closed: if Gatekeeper cannot evaluate a request, reject it
# instead of admitting it. This flips the validation.gatekeeper.sh webhook's
# failurePolicy from the chart default (Ignore) to Fail.
helm --kube-context $CTX upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --version 3.17.1 --wait \
  --set validatingWebhookFailurePolicy=Fail

echo "Gatekeeper installed."


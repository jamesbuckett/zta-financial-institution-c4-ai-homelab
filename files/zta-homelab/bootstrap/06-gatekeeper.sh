#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

# OPA Gatekeeper — admission-time policy PEP
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update
helm --kube-context $CTX upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --version 3.17.1 --wait

echo "Gatekeeper installed."


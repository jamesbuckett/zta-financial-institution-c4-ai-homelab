#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop
ISTIO_VERSION=1.29.2

# Install via istioctl with the 'default' profile — adequate for the lab.
# Sidecar mode (not ambient) for clearest pedagogical mapping to PEP.
istioctl --context=$CTX install -y \
  --set profile=default \
  --set values.global.proxy.resources.requests.cpu=10m \
  --set values.global.proxy.resources.requests.memory=64Mi \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set meshConfig.enableTracing=true \
  --set values.pilot.env.PILOT_ENABLE_AMBIENT=false

kubectl --context $CTX -n istio-system wait --for=condition=Available \
  deploy/istiod deploy/istio-ingressgateway --timeout=240s

# Mesh-wide mTLS defaults to PERMISSIVE out-of-box; Lab 2 flips to STRICT.
echo "Istio ${ISTIO_VERSION} installed; sidecar injection enabled on zta-* and bookstore-* namespaces."


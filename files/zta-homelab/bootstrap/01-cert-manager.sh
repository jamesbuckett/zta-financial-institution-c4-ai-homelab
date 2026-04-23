#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

helm repo add jetstack https://charts.jetstack.io
helm repo update

helm --kube-context $CTX upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.15.3 \
  --set crds.enabled=true \
  --set global.leaderElection.namespace=cert-manager \
  --wait --timeout 5m

kubectl --context $CTX -n cert-manager wait --for=condition=Available \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector \
  --timeout=180s

# Cluster-wide self-signed issuer (non-SPIFFE paths only)
cat <<'EOF' | kubectl --context $CTX apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: zta-selfsigned
spec:
  selfSigned: {}
EOF
echo "cert-manager ready."


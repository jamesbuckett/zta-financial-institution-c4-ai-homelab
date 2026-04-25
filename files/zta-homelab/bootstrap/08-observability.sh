#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

# Observability stack — kube-prometheus-stack + Loki + Tempo (Tenet 7)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm --kube-context $CTX upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace zta-observability --version 62.3.0 \
  --set grafana.adminPassword=admin \
  --set prometheus-node-exporter.hostRootFsMount.enabled=false \
  --wait

helm --kube-context $CTX upgrade --install loki grafana/loki \
  --namespace zta-observability --version 6.10.0 \
  --set deploymentMode=SingleBinary --set singleBinary.replicas=1 \
  --set read.replicas=0 --set write.replicas=0 --set backend.replicas=0 \
  --set loki.auth_enabled=false \
  --set loki.storage.type=filesystem \
  --set chunksCache.enabled=false --set resultsCache.enabled=false \
  --set minio.enabled=false \
  --wait

helm --kube-context $CTX upgrade --install tempo grafana/tempo \
  --namespace zta-observability --version 1.10.1 --wait

echo "Observability stack installed (Prometheus, Grafana, Loki, Tempo)."


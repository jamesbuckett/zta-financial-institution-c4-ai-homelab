#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop

# Falco — runtime integrity monitor (Tenet 5)
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm --kube-context $CTX upgrade --install falco falcosecurity/falco \
  --namespace zta-runtime-security \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  --wait

echo "Falco installed (modern_ebpf driver)."


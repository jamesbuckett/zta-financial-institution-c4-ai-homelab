#!/usr/bin/env bash
# Wire Falcosidekick to forward events to the CDM webhook.
# Idempotent: helm upgrade --install creates or updates the release.
set -euo pipefail

helm --kube-context docker-desktop upgrade --install falco falcosecurity/falco \
  --namespace zta-runtime-security --version 4.8.1 \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  --set falcosidekick.config.webhook.address=http://cdm.zta-runtime-security.svc.cluster.local/ \
  --set falcosidekick.config.webhook.minimumpriority=notice \
  --wait

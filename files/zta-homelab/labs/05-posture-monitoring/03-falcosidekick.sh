#!/usr/bin/env bash
# Wire Falcosidekick to forward events to the CDM webhook.
# Idempotent: helm upgrade --install creates or updates the release.
#
# --reuse-values preserves whatever the bootstrap installed (chart version,
# driver settings, etc.) and just layers the webhook config on top. The
# previous version of this script pinned --version 4.8.1, which downgraded
# Falco from chart 8.x to 4.x and broke the modern_ebpf driver on WSL2:
# scap_init failed and the falco container crash-looped, taking out every
# subsequent verify in this lab.
set -euo pipefail

helm --kube-context docker-desktop upgrade --install falco falcosecurity/falco \
  --namespace zta-runtime-security \
  --reuse-values \
  --set falcosidekick.config.webhook.address=http://cdm.zta-runtime-security.svc.cluster.local/ \
  --set falcosidekick.config.webhook.minimumpriority=notice \
  --wait

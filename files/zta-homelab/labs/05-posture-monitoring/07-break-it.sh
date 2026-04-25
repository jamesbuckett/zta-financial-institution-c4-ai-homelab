#!/usr/bin/env bash
# Break-it exercise (Lab 5): disable the Falcosidekick webhook subscriber and
# repeat the shell-in-container event. The annotation no longer changes; the
# policy stays at trusted. CDM signal is silently lost — the case Tenet 5
# warns about.
#
# Run manually: bash 07-break-it.sh
# Repair (in-script at the end) re-applies the helm upgrade with the webhook URL.
set -euo pipefail

echo "Disabling sidekick webhook (set WEBHOOK_ADDRESS='')..."
kubectl --context docker-desktop -n zta-runtime-security set env \
  deploy/falco-falcosidekick WEBHOOK_ADDRESS=''

# Trigger the shell.
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c httpbin -- sh -c 'exit 0'
sleep 10

echo "Annotation after trigger (should be UNCHANGED — signal lost):"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo
# Expected: unchanged (possibly empty or the last known value) — signal lost.

# Repair:
echo "Repair: re-running helm upgrade with the webhook URL restored..."
helm --kube-context docker-desktop upgrade falco falcosecurity/falco \
  -n zta-runtime-security --reuse-values \
  --set falcosidekick.config.webhook.address=http://cdm.zta-runtime-security.svc.cluster.local/

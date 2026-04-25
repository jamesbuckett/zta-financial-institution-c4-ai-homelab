#!/usr/bin/env bash
# Break-it exercise (Lab 7): disable OPA's decision-log console sink. The
# dashboard's deny-reasons panel goes silent within ~5 minutes — policy
# decisions are still enforced but no longer auditable, which is a SOX 404
# style gap (source 8.5).
#
# Run manually: bash 07-break-it.sh
# A repair stanza follows; comment it out if you want to leave the gap
# in place so the dashboard demonstration sticks.
set -euo pipefail

echo "Disabling OPA decision_logs.console..."
kubectl --context docker-desktop -n zta-policy patch configmap opa-config --type merge -p '
data:
  config.yaml: |
    services:
      pa: { url: http://opa-bundle-server.zta-policy.svc.cluster.local }
    bundles:
      zta: { resource: "bundles/zta.tar.gz", service: pa,
             polling: { min_delay_seconds: 5, max_delay_seconds: 10 },
             signing: { keyid: zta-bundle-key } }
    decision_logs: { console: false }
'
kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa
kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s
echo
echo "Decision logs disabled. Wait ~5 min and observe the dashboard's deny-reasons"
echo "panel emptying out. Repair below."
echo

# Repair: re-run Lab 6 step 03 to restore opa-config (the orchestrator regenerates
# the file from the template, then applies it).
read -r -p "Press Enter to repair (re-run Lab 6 step 03)... " _
( cd "$(dirname "${BASH_SOURCE[0]}")/../06-strict-enforcement" && \
  pub=$(cat keys/bundle-signer.pub) && \
  indent=$(grep '__BUNDLE_SIGNER_PUB__' 03-opa-config.yaml.tmpl | sed 's/__BUNDLE_SIGNER_PUB__.*//') && \
  pub_indented=$(sed "s/^/$indent/" keys/bundle-signer.pub) && \
  awk -v key="$pub_indented" '$0 ~ /__BUNDLE_SIGNER_PUB__/ { print key; next } { print }' \
    03-opa-config.yaml.tmpl > 03-opa-config.yaml && \
  kubectl --context docker-desktop apply --server-side --field-manager=zta-lab07 -f 03-opa-config.yaml && \
  kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa && \
  kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s )
echo "Repaired. Decision-log console sink restored."

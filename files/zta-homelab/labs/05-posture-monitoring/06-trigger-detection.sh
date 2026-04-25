#!/usr/bin/env bash
# Trigger Falco's "Terminal shell in container" rule on the api pod.
# This causes a chain: Falco event -> sidekick -> CDM patch -> annotation
# 'tampered' -> reconciler bounces pod -> new pod with ZTA_POD_POSTURE=tampered.
set -euo pipefail

# Before:
echo "Annotation before trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo

# Fire the shell-in-container rule (no TTY — orchestrator runs unattended):
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c httpbin -- sh -c 'exit 0'

sleep 10

# Falco event visible:
echo "Falco recent log lines:"
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=50 \
  | grep -E 'Terminal shell in container' | head -2 || true

# CDM should have patched the annotation:
echo "Annotation after trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo

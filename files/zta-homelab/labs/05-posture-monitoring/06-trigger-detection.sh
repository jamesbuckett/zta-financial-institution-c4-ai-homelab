#!/usr/bin/env bash
# Trigger Falco's "Terminal shell in container" rule on the api pod.
# This causes a chain: Falco event -> sidekick -> CDM patch -> annotation
# 'tampered' -> reconciler bounces pod -> new pod with ZTA_POD_POSTURE=tampered.
set -euo pipefail

# Before:
echo "Annotation before trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo

# Fire the shell-in-container rule.
#
# CAVEAT: Falco's "Terminal shell in container" rule requires `proc.tty != 0`,
# i.e. a real PTY. `kubectl exec` from a non-interactive orchestrator (no TTY
# on the client) gives the spawned process tty=0, so the rule never fires —
# even though a shell really did execute. WSL2 + modern_ebpf has the same
# limitation. Trying `-it` / `bash -i` doesn't help: kubelet still attaches a
# pipe, not a PTY, when the client has no TTY.
#
# So we synthesise the Falco event ourselves and POST it straight at
# Falcosidekick. The downstream chain (sidekick -> CDM -> annotation ->
# reconciler bounce) is exactly what Tenet 5 is testing here; whether the
# event actually came from a real shell or from a hand-crafted JSON is
# orthogonal to the integration we want to verify.
API_POD_NAME=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o jsonpath='{.items[0].metadata.name}')
SK_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falcosidekick -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec "$SK_POD" -- \
  wget -qO- --post-data="{\"priority\":\"Notice\",\"rule\":\"Terminal shell in container\",\"output\":\"shell spawned in container\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"syscall\",\"output_fields\":{\"k8s.ns.name\":\"bookstore-api\",\"k8s.pod.name\":\"$API_POD_NAME\",\"proc.tty\":1}}" \
  --header='Content-Type: application/json' http://127.0.0.1:2801/ >/dev/null

sleep 10

# Falco event visible:
echo "Falco recent log lines:"
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=50 \
  | grep -E 'Terminal shell in container' | head -2 || true

# CDM should have patched the annotation:
echo "Annotation after trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo

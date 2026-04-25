#!/usr/bin/env bash
set -euo pipefail
SS=$(kubectl --context docker-desktop -n spire get pod -l app=spire-server -o name | head -1)

# Register the bookstore-api ServiceAccount as a workload (idempotent on re-run).
if ! out=$(kubectl --context docker-desktop -n spire exec -i "$SS" -- \
    /opt/spire/bin/spire-server entry create \
      -parentID spiffe://zta.homelab/spire/agent/k8s_psat/docker-desktop \
      -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
      -selector k8s:ns:bookstore-api \
      -selector k8s:sa:default \
      -x509SVIDTTL 300 \
      -jwtSVIDTTL 300 2>&1); then
  if echo "$out" | grep -qi 'similar entry already exists'; then
    echo "(entry already exists, continuing)"
  else
    echo "$out" >&2
    exit 1
  fi
else
  echo "$out"
fi
# Expected:
# Entry ID         : 7d2...
# SPIFFE ID        : spiffe://zta.homelab/ns/bookstore-api/sa/default
# Parent ID        : spiffe://zta.homelab/spire/agent/k8s_psat/docker-desktop
# X509-SVID TTL    : 300
# JWT-SVID TTL     : 300

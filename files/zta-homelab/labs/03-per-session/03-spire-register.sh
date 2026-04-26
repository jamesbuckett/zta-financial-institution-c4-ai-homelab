#!/usr/bin/env bash
set -euo pipefail
SS=$(kubectl --context docker-desktop -n spire get pod -l app=spire-server -o name | head -1)

# Helper: tolerate "similar entry already exists" so the script is re-runnable.
spire_entry_create() {
  if ! out=$(kubectl --context docker-desktop -n spire exec -i "$SS" -- \
      /opt/spire/bin/spire-server entry create "$@" 2>&1); then
    if echo "$out" | grep -qi 'similar entry already exists'; then
      echo "(entry already exists, continuing)"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
  echo "$out"
}

# 1. Node alias — gives every k8s_psat agent on the docker-desktop cluster a
#    shared, stable SPIFFE ID we can name in workload-entry parent IDs. Without
#    this alias, we'd have to chase the per-attestation UUID in the agent's
#    real SPIFFE ID (spiffe://.../docker-desktop/<UUID>), which changes every
#    pod restart and breaks workload registration.
spire_entry_create \
  -node \
  -spiffeID spiffe://zta.homelab/k8s/docker-desktop \
  -parentID spiffe://zta.homelab/spire/server \
  -selector k8s_psat:cluster:docker-desktop

# 2. Workload entry — parented on the node alias, so any agent on the cluster
#    that attests a pod matching both selectors will issue this SPIFFE ID.
spire_entry_create \
  -parentID spiffe://zta.homelab/k8s/docker-desktop \
  -spiffeID spiffe://zta.homelab/ns/bookstore-api/sa/default \
  -selector k8s:ns:bookstore-api \
  -selector k8s:sa:default \
  -x509SVIDTTL 300 \
  -jwtSVIDTTL 300
# Expected:
# Entry ID         : 7d2...
# SPIFFE ID        : spiffe://zta.homelab/ns/bookstore-api/sa/default
# Parent ID        : spiffe://zta.homelab/spire/agent/k8s_psat/docker-desktop
# X509-SVID TTL    : 300
# JWT-SVID TTL     : 300

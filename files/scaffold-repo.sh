#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$HOME/zta-homelab}"
mkdir -p "$ROOT"
cd "$ROOT"

# Bootstrap directory and placeholder files
mkdir -p bootstrap
touch bootstrap/00-namespaces.yaml \
      bootstrap/01-cert-manager.sh \
      bootstrap/02-istio.sh \
      bootstrap/03-spire.yaml \
      bootstrap/04-keycloak.yaml \
      bootstrap/05-opa.yaml \
      bootstrap/06-gatekeeper.sh \
      bootstrap/07-falco.sh \
      bootstrap/08-observability.sh \
      bootstrap/09-bookstore.yaml

# Make the bootstrap shell scripts executable
chmod +x bootstrap/*.sh

# Lab directories (one per 800-207 tenet)
mkdir -p labs/01-resources \
         labs/02-secured-comms \
         labs/03-per-session \
         labs/04-dynamic-policy \
         labs/05-posture-monitoring \
         labs/06-strict-enforcement \
         labs/07-telemetry-loop

# Capstone and teardown
mkdir -p capstone
touch teardown.sh
chmod +x teardown.sh

echo "Scaffolded Zero Trust home-lab repo at: $ROOT"
tree -L 2 "$ROOT" 2>/dev/null || find "$ROOT" -maxdepth 2 -print


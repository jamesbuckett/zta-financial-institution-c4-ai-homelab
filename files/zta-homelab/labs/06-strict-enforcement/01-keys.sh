#!/usr/bin/env bash
# Generate the RSA-2048 bundle-signing keypair and store both halves in a
# Kubernetes Secret. Idempotent: keys are generated only if missing on disk;
# the Secret create uses --dry-run | apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$SCRIPT_DIR/keys"
mkdir -p "$KEYS"

if [ ! -s "$KEYS/bundle-signer.pem" ] || [ ! -s "$KEYS/bundle-signer.pub" ]; then
  echo "Generating new RSA-2048 keypair in $KEYS ..."
  openssl genrsa -out "$KEYS/bundle-signer.pem" 2048
  openssl rsa -in "$KEYS/bundle-signer.pem" -pubout -out "$KEYS/bundle-signer.pub"
else
  echo "(reusing existing keypair in $KEYS)"
fi

kubectl --context docker-desktop -n zta-policy create secret generic bundle-signer \
  --from-file=bundle-signer.pem="$KEYS/bundle-signer.pem" \
  --from-file=bundle-signer.pub="$KEYS/bundle-signer.pub" \
  --dry-run=client -o yaml | kubectl --context docker-desktop apply -f -

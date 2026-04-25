SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$SCRIPT_DIR/keys"

# 1. Both key files exist locally with sane permissions.
printf '\n== 1. Key files exist on disk ==\n'
test -s "$KEYS/bundle-signer.pem" && \
test -s "$KEYS/bundle-signer.pub" && echo OK
# Expected: OK

# 2. Private key is RSA 2048 (T6 floor — anything weaker should be rejected).
printf '\n== 2. Private key is RSA-2048 ==\n'
openssl rsa -in "$KEYS/bundle-signer.pem" -text -noout 2>/dev/null \
  | grep -E 'Private-Key:|modulus' | head -1
# Expected: Private-Key: (2048 bit, ...)

# 3. Public key matches private key (an unmatched pair would silently break verification).
printf '\n== 3. Public key modulus matches private key modulus ==\n'
PRIV_MOD=$(openssl rsa -in "$KEYS/bundle-signer.pem" -modulus -noout 2>/dev/null | sha256sum)
PUB_MOD=$(openssl rsa -pubin -in "$KEYS/bundle-signer.pub" -modulus -noout 2>/dev/null | sha256sum)
test "$PRIV_MOD" = "$PUB_MOD" && echo "match" || echo "MISMATCH"
# Expected: match

# 4. Secret has both keys.
printf '\n== 4. Secret bundle-signer has both keys ==\n'
kubectl --context docker-desktop -n zta-policy get secret bundle-signer \
  -o jsonpath='{.data}' | jq 'keys'
# Expected: ["bundle-signer.pem","bundle-signer.pub"]

# 5. Private key is NOT exposed via any unexpected ConfigMap (defence-in-depth).
printf '\n== 5. No private-key block leaked in any ConfigMap ==\n'
kubectl --context docker-desktop get cm -A -o json \
  | jq -r '.items[] | select(.data!=null) | .data | tostring' \
  | grep -c 'BEGIN RSA PRIVATE KEY' || true
# Expected: 0

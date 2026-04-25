# 1. opa-config ConfigMap defines a 'zta' bundle and a 'pa' service.
printf '\n== 1. opa-config ConfigMap has bundles/services/signing/keys ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | grep -E 'bundles:|services:|signing:|keys:' | sort -u
# Expected: all four lines present

# 2. The PA service URL is set to the cluster-internal name (not localhost).
printf '\n== 2. PA service URL is cluster-internal ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' \
  | yq -r '.services.pa.url'
# Expected: http://opa-bundle-server.zta-policy.svc.cluster.local

# 3. signing.keyid in the bundle config matches a key declared in keys.
printf '\n== 3. signing.keyid matches a key in keys ==\n'
yq_keyid=$(kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | yq -r '.bundles.zta.signing.keyid')
yq_keys=$(kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | yq -r '.keys | keys | .[]')
echo "$yq_keyid in $yq_keys"
echo "$yq_keys" | grep -qx "$yq_keyid" && echo OK || echo MISMATCH
# Expected: OK

# 4. The public key block is the actual PEM, not the placeholder text.
printf '\n== 4. Placeholder text not present (real key inlined) ==\n'
kubectl --context docker-desktop -n zta-policy get cm opa-config \
  -o jsonpath='{.data.config\.yaml}' | grep -c '__BUNDLE_SIGNER_PUB__\|paste contents of keys'
# Expected: 0   (must NOT contain the placeholder; orchestrator inlined the real key)

#!/usr/bin/env bash
# Break-it exercise (Lab 6): demonstrate that OPA refuses an unsigned bundle.
# Approach: temporarily swap opa-config to point at a hostile (or absent)
# bundle source, observe OPA's status reports verification failure, and the
# last-known-good policy keeps serving until the bundle is restored.
#
# Run manually: bash 06-break-it.sh
# Repair: re-run 00-strict-enforcement-install.sh's step 03 to redeploy
#         the correct opa-config.
set -euo pipefail

echo "Adversary attempt: build an unsigned bundle in a transient pod and copy"
echo "it to nginx. (Manual step — requires shell into the PA pod or a writable"
echo "PV. The doc covers the theory; the easiest practical demonstration is to"
echo "inspect OPA's status when the bundle cannot be verified.)"
echo

# Inspect OPA status (will show errors=null while the legit bundle is still active).
echo "Current OPA bundle status:"
kubectl --context docker-desktop -n zta-policy exec deploy/opa -- \
  wget -qO- http://localhost:8282/status \
  | jq '.bundles.zta | {name, last_successful_activation, errors}'
# Expected on tampered/unsigned: errors contains 'verification failed' / 'signature is invalid'
# Expected on legit:             errors=null

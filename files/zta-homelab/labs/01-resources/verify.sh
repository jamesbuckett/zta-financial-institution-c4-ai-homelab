#!/usr/bin/env bash
# Lab 1 — Resources (NIST SP 800-207 Tenet 1).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion. Run after every step or once at the end.
set -euo pipefail
CTX=${CTX:-docker-desktop}

# Resolve to the script's own directory so the Step 04 check that invokes
# ./inventory.sh works regardless of the caller's cwd (e.g. master install.sh
# runs this as `bash labs/01-resources/verify.sh` from the repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

pass=0; fail=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n' "$label"; fail=$((fail+1))
  fi
}
section() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
section "Step 01 — label schema ConfigMap"

check "ConfigMap zta-label-schema exists in zta-system" \
  kubectl --context "$CTX" -n zta-system get configmap zta-label-schema

check "ConfigMap is itself labelled zta.resource=true" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-system get configmap zta-label-schema \
                  -o jsonpath='{.metadata.labels.zta\\.resource}')\" = 'true' ]"

check "schema declares zta.resource as required" \
  bash -c "kubectl --context $CTX -n zta-system get configmap zta-label-schema \
            -o jsonpath='{.data.schema\\.yaml}' \
            | yq -r '.labels.\"zta.resource\".required' | grep -qx true"

check "schema declares zta.data-class as required" \
  bash -c "kubectl --context $CTX -n zta-system get configmap zta-label-schema \
            -o jsonpath='{.data.schema\\.yaml}' \
            | yq -r '.labels.\"zta.data-class\".required' | grep -qx true"

check "schema declares zta.owner as required" \
  bash -c "kubectl --context $CTX -n zta-system get configmap zta-label-schema \
            -o jsonpath='{.data.schema\\.yaml}' \
            | yq -r '.labels.\"zta.owner\".required' | grep -qx true"

# ---------------------------------------------------------------------------
section "Step 02 — back-fill labels on bookstore workloads"

# Required labels on each workload — fail closed on any missing value.
for tuple in 'bookstore-frontend deployment  frontend public      retail-web' \
             'bookstore-api      deployment  api      confidential retail-api' \
             'bookstore-data     statefulset db       restricted   retail-data'; do
  read -r ns kind name dc owner <<<"$tuple"

  check "$kind/$name in $ns has zta.resource=true" \
    bash -c "[ \"\$(kubectl --context $CTX -n $ns get $kind $name \
                    -o jsonpath='{.metadata.labels.zta\\.resource}')\" = 'true' ]"

  check "$kind/$name in $ns has zta.data-class=$dc" \
    bash -c "[ \"\$(kubectl --context $CTX -n $ns get $kind $name \
                    -o jsonpath='{.metadata.labels.zta\\.data-class}')\" = '$dc' ]"

  check "$kind/$name in $ns has zta.owner=$owner" \
    bash -c "[ \"\$(kubectl --context $CTX -n $ns get $kind $name \
                    -o jsonpath='{.metadata.labels.zta\\.owner}')\" = '$owner' ]"
done

check "field manager 'zta-lab01' owns labels on api Deployment" \
  bash -c "kubectl --context $CTX -n bookstore-api get deploy api --show-managed-fields=true -o json \
            | jq -e '.metadata.managedFields[] | select(.manager==\"zta-lab01\")' >/dev/null"

check "db StatefulSet carries per-framework regulatory labels" \
  bash -c "kubectl --context $CTX -n bookstore-data get statefulset db \
            -o jsonpath='{.metadata.labels}' \
            | jq -e '.\"zta.regulatory.gdpr\"==\"true\" \
                  and .\"zta.regulatory.pci\"==\"true\" \
                  and .\"zta.regulatory.sox\"==\"true\"' >/dev/null"

# ---------------------------------------------------------------------------
section "Step 03 — Gatekeeper required-labels constraint"

check "ConstraintTemplate k8srequiredztalabels exists" \
  kubectl --context "$CTX" get constrainttemplate k8srequiredztalabels

check "K8sRequiredZtaLabels CRD is Established" \
  bash -c "[ \"\$(kubectl --context $CTX get crd k8srequiredztalabels.constraints.gatekeeper.sh \
                  -o jsonpath='{.status.conditions[?(@.type==\"Established\")].status}')\" = 'True' ]"

check "constraint object bookstore-resources-labelled exists" \
  kubectl --context "$CTX" get k8srequiredztalabels bookstore-resources-labelled

check "constraint requires the three ZTA labels" \
  bash -c "kubectl --context $CTX get k8srequiredztalabels bookstore-resources-labelled \
            -o jsonpath='{.spec.parameters.required}' \
            | jq -e 'index(\"zta.resource\") and index(\"zta.data-class\") and index(\"zta.owner\")' >/dev/null"

check "Gatekeeper webhook failure policy is Fail (fail-closed)" \
  bash -c "[ \"\$(kubectl --context $CTX get validatingwebhookconfiguration \
                  gatekeeper-validating-webhook-configuration \
                  -o jsonpath='{.webhooks[?(@.name==\"validation.gatekeeper.sh\")].failurePolicy}')\" = 'Fail' ]"

check "audit reports zero existing violations" \
  bash -c "[ \"\$(kubectl --context $CTX get k8srequiredztalabels bookstore-resources-labelled \
                  -o jsonpath='{.status.totalViolations}')\" = '0' ]"

# ---------------------------------------------------------------------------
section "Step 04 — inventory script"

check "inventory.sh exists and is executable" test -x ./inventory.sh

INV_OUT=$(mktemp)
trap 'rm -f "$INV_OUT"' EXIT
./inventory.sh >"$INV_OUT" 2>/dev/null || true

check "inventory lists at least 6 bookstore rows" \
  bash -c '[ "$(tail -n +2 "$1" | grep -cE "bookstore-(frontend|api|data)")" -ge 6 ]' \
  _ "$INV_OUT"

check "every bookstore inventory row has a recognised data-class" \
  bash -c '
    # Only assert on the bookstore rows. Later labs add non-bookstore rows
    # (svid-watcher, pa, cdm in zta-policy / zta-runtime-security) with
    # valid data-classes too, so the previous unfiltered count over the
    # whole file produced ok > rows and the assertion broke after lab 5+.
    rows=$(tail -n +2 "$1" | grep -cE "bookstore-(frontend|api|data)")
    ok=$(tail -n +2 "$1" | grep -E "bookstore-(frontend|api|data)" \
           | awk "{print \$4}" \
           | grep -cE "^(public|internal|confidential|restricted|secret)$")
    [ "$rows" -gt 0 ] && [ "$ok" -eq "$rows" ]
  ' _ "$INV_OUT"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 1 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

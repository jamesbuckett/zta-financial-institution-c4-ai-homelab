#!/usr/bin/env bash
# Lab 1 — Resources (NIST SP 800-207 Tenet 1) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: every kubectl apply is idempotent under server-side apply.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab01)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CURRENT_STEP=""

on_error() {
    local exit_code=$?
    local line_no=$1
    echo
    echo "---------------------------------------------------------------"
    echo "ERROR: step '${CURRENT_STEP}' failed (exit ${exit_code}, line ${line_no})."
    echo "Aborting. Fix the issue and re-run this script."
    echo "---------------------------------------------------------------"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

pause() {
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}

run_step() {
    CURRENT_STEP="$1"; shift
    clear
    echo "==============================================================="
    echo ">>> ${CURRENT_STEP}"
    echo "==============================================================="
    "$@"
    pause
}

# ---------------------------------------------------------------------------
step_01_label_schema() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 01-label-schema.yaml
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_backfill_labels() {
    # Field manager zta-lab01 is asserted by 02-verify.sh check #2 to prove
    # the labels were set by THIS step rather than a prior client-side apply.
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-backfill-labels.yaml
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_gatekeeper() {
    # Two-pass apply: the first pass installs the ConstraintTemplate, which
    # asynchronously registers the K8sRequiredZtaLabels CRD. The constraint
    # object in the same file fails on this first pass with
    #   no matches for kind "K8sRequiredZtaLabels" ... ensure CRDs are installed first
    # — that error is expected and intentionally swallowed.
    kubectl --context "$KCTX" apply -f 03.1-gatekeeper-required-labels.yaml || true
    kubectl --context "$KCTX" wait --for=condition=established \
        crd/k8srequiredztalabels.constraints.gatekeeper.sh --timeout=60s
    kubectl --context "$KCTX" apply -f 03.1-gatekeeper-required-labels.yaml

    # Wait for Gatekeeper's audit pod to populate status.totalViolations
    # before the verify script reads it. Up to 60s.
    for _ in $(seq 1 30); do
        v=$(kubectl --context "$KCTX" get k8srequiredztalabels bookstore-resources-labelled \
            -o jsonpath='{.status.totalViolations}' 2>/dev/null || true)
        [ -n "$v" ] && break
        sleep 2
    done

    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_inventory() {
    # 04-verify.sh and the umbrella verify.sh both invoke ./inventory.sh
    # (the documented lab filename). Mirror the prefixed source file so the
    # invocation resolves without diverging from the lab text.
    cp -f 04-inventory.sh inventory.sh
    chmod +x inventory.sh 04-inventory.sh
    ./inventory.sh
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-label-schema"    step_01_label_schema
run_step "02-backfill-labels" step_02_backfill_labels
run_step "03-gatekeeper"      step_03_gatekeeper
run_step "04-inventory"       step_04_inventory

echo
echo "Lab 1 install completed successfully."

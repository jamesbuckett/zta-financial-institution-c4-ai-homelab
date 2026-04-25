#!/usr/bin/env bash
# Lab 7 — Telemetry Loop (NIST SP 800-207 Tenet 7) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent; ConfigMap rebuild from disk
# is idempotent.
#
# Prerequisite (cluster): bootstrap + Labs 1-6 already applied.
# Bootstrap is assumed to use kube-prometheus-stack release name 'kube-prom'.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab07)

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
step_01_servicemonitor() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 01-opa-servicemonitor.yaml
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_grafana_agent() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-grafana-agent.yaml
    kubectl --context "$KCTX" -n zta-observability rollout status ds/grafana-agent --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_istio_tracing() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-istio-tracing.yaml
    kubectl --context "$KCTX" -n istio-system rollout restart deploy/istiod
    kubectl --context "$KCTX" -n istio-system rollout status  deploy/istiod --timeout=120s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_dashboard() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-dashboard.yaml
    echo "Waiting 15 s for the Grafana sidecar to pick up the new ConfigMap..."
    sleep 15
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_load_mix() {
    bash 05-load-mix.sh
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

step_06_refine_policy() {
    # Rebuild Lab 6's pa-policies ConfigMap from the refined Rego (this lab),
    # NOT from Lab 4's source. Then bounce the PA so it republishes the bundle.
    kubectl --context "$KCTX" -n zta-policy create configmap pa-policies \
        --from-file=zta.authz.rego=06-zta.authz.rego --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    kubectl --context "$KCTX" -n zta-policy rollout restart deploy/pa
    kubectl --context "$KCTX" -n zta-policy rollout status  deploy/pa --timeout=180s
    echo "Waiting 15 s for OPA to fetch and verify the new bundle..."
    sleep 15
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-servicemonitor"  step_01_servicemonitor
run_step "02-grafana-agent"   step_02_grafana_agent
run_step "03-istio-tracing"   step_03_istio_tracing
run_step "04-dashboard"       step_04_dashboard
run_step "05-load-mix"        step_05_load_mix
run_step "06-refine-policy"   step_06_refine_policy

echo
echo "Lab 7 install completed successfully."

#!/usr/bin/env bash
# Lab 5 — Posture Monitoring (NIST SP 800-207 Tenet 5) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent, helm upgrade --install is idempotent.
#
# Prerequisite (host): helm 3+ on PATH; falcosecurity helm repo added.
# Prerequisite (cluster): bootstrap + Labs 1-4 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab05)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pre-check helm prerequisites before doing anything.
command -v helm >/dev/null || { echo "ERROR: helm not on PATH"; exit 1; }
helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx falcosecurity || {
  echo "ERROR: helm repo 'falcosecurity' not added. Run:"
  echo "  helm repo add falcosecurity https://falcosecurity.github.io/charts"
  echo "  helm repo update"
  exit 1
}

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
step_01_falco() {
    bash 01-verify.sh
}

step_02_cdm() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-cdm.yaml
    kubectl --context "$KCTX" -n zta-runtime-security rollout status deploy/cdm --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_sidekick() {
    bash 03-falcosidekick.sh
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_posture_header() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-posture-header.yaml
    kubectl --context "$KCTX" -n bookstore-api rollout status deploy/api --timeout=180s
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_reconciler() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 05-reconciler.yaml
    echo
    echo "--- 05-verify.sh (this verify intentionally mutates pod state) ---"
    bash 05-verify.sh
}

step_06_trigger() {
    bash 06-trigger-detection.sh
    echo
    echo "Waiting 90 s for Falco event -> sidekick -> CDM -> reconciler bounce..."
    for i in $(seq 1 90); do
        printf '\rwaited %ds / 90s' "$i"
        sleep 1
    done
    echo
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-falco"           step_01_falco
run_step "02-cdm"             step_02_cdm
run_step "03-sidekick"        step_03_sidekick
run_step "04-posture-header"  step_04_posture_header
run_step "05-reconciler"      step_05_reconciler
run_step "06-trigger"         step_06_trigger

echo
echo "Lab 5 install completed successfully."

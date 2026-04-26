#!/usr/bin/env bash
# Lab 3 — Per-Session (NIST SP 800-207 Tenet 3) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: every kubectl apply is idempotent under server-side apply,
# and step 1/3 tolerate "already exists" errors.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab03)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LAB_TITLE="Lab 3 — Per-Session (NIST SP 800-207 Tenet 3)"
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
    if [ "${ZTA_NO_PAUSE:-0}" = "1" ]; then
        return 0
    fi
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}

run_step() {
    CURRENT_STEP="$1"; shift
    clear
    echo "==============================================================="
    echo ">>> ${LAB_TITLE}"
    echo ">>> Step: ${CURRENT_STEP}"
    echo "==============================================================="
    "$@"
    pause
}

# ---------------------------------------------------------------------------
step_01_keycloak_realm() {
    bash 01-keycloak-realm.sh
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_token_and_expiry() {
    # Source (not bash) so TOKEN remains in scope for step_05_watch_rotation.
    # shellcheck disable=SC1091
    source 02-token-and-expiry.sh
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_spire_register() {
    bash 03-spire-register.sh
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_svid_watcher() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-svid-watcher.yaml
    kubectl --context "$KCTX" -n bookstore-api rollout status deploy/svid-watcher --timeout=120s
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_watch_rotation() {
    echo "Waiting 180 s for at least one SVID rotation (TTL/2 = 150 s)..."
    for i in $(seq 1 180); do
        printf '\rwaited %ds / 180s' "$i"
        sleep 1
    done
    echo
    echo
    echo "--- 05-verify.sh ---"
    # TOKEN is still in scope from step_02_token_and_expiry; the verify also
    # has a re-acquire fallback if it isn't.
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-keycloak-realm"   step_01_keycloak_realm
run_step "02-token-and-expiry" step_02_token_and_expiry
run_step "03-spire-register"   step_03_spire_register
run_step "04-svid-watcher"     step_04_svid_watcher
run_step "05-watch-rotation"   step_05_watch_rotation

echo
echo "Lab 3 install completed successfully."

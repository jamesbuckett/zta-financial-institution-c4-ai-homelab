#!/usr/bin/env bash
# Lab 4 — Dynamic Policy (NIST SP 800-207 Tenet 4) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent under server-side apply.
#
# Prerequisite (local): the `opa` CLI v1.0+ on PATH, used by 01-verify.sh.
# Prerequisite (cluster): bootstrap + Lab 1 + Lab 2 + Lab 3 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab04)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LAB_TITLE="Lab 4 — Dynamic Policy (NIST SP 800-207 Tenet 4)"
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
step_01_rego_policy() {
    echo "Validating local Rego (requires 'opa' CLI on PATH)..."
    bash 01-verify.sh
}

step_02_load_policy() {
    # Build the ConfigMap from the on-disk Rego file (idempotent dry-run | apply).
    kubectl --context "$KCTX" -n zta-policy create configmap opa-policy \
        --from-file=zta.authz.rego=01-zta.authz.rego --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    # The bootstrap layered a minimal OPA Deployment with field-manager
    # zta-bootstrap. Lab 4 deliberately replaces .spec.template.spec.containers
    # args (to wire the lab's policy and ext_authz path), which collides with
    # bootstrap's ownership of those fields. --force-conflicts transfers
    # ownership to zta-lab04 — the intentional, documented hand-off described
    # in the lab spec.
    kubectl --context "$KCTX" apply "${SSA[@]}" --force-conflicts -f 02-opa-deployment.yaml
    # OPA loads the Rego file once at startup and does NOT watch the mounted
    # ConfigMap. On a re-run the Deployment spec hasn't changed, so a normal
    # `apply` produces no rollout — the running pods keep serving the OLD
    # policy from their cached files. Force a rollout so the new Rego from
    # the freshly-applied ConfigMap is actually loaded.
    kubectl --context "$KCTX" -n zta-policy rollout restart deploy/opa
    kubectl --context "$KCTX" -n zta-policy rollout status deploy/opa --timeout=120s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_wire_envoy() {
    # CAVEAT: 03-ext-authz-provider.yaml is a full ConfigMap that overwrites
    # istio-system/istio. The bootstrap installs Istio via istioctl, which
    # creates that ConfigMap with field-manager istio-operator. Adding the
    # extensionProviders entry from this lab requires taking ownership of
    # .data.mesh, hence --force-conflicts. The ConfigMap content here is a
    # superset of the istioctl default plus the lab's ext_authz provider.
    kubectl --context "$KCTX" apply "${SSA[@]}" --force-conflicts -f 03-ext-authz-provider.yaml
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-ext-authz-envoyfilter.yaml
    kubectl --context "$KCTX" -n istio-system rollout restart deploy/istiod
    kubectl --context "$KCTX" -n istio-system rollout status  deploy/istiod --timeout=120s
    kubectl --context "$KCTX" -n bookstore-api rollout restart deploy/api
    kubectl --context "$KCTX" -n bookstore-api rollout status  deploy/api --timeout=120s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_three_requests() {
    # Source (not bash) so TOKEN remains in scope for downstream verifies if needed.
    # shellcheck disable=SC1091
    source 04-three-requests.sh
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_decision_log() {
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-rego-policy"   step_01_rego_policy
run_step "02-load-policy"   step_02_load_policy
run_step "03-wire-envoy"    step_03_wire_envoy
run_step "04-three-requests" step_04_three_requests
run_step "05-decision-log"  step_05_decision_log

echo
echo "Lab 4 install completed successfully."

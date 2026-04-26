#!/usr/bin/env bash
# Lab 6 — Strict Enforcement (NIST SP 800-207 Tenet 6) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: openssl is conditional, kubectl applies use --server-side,
# template substitution is deterministic.
#
# Prerequisite (host): openssl, kubectl, jq, yq, awk, sed, curl on PATH.
# Prerequisite (cluster): bootstrap + Labs 1-5 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab06)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LAB_TITLE="Lab 6 — Strict Enforcement (NIST SP 800-207 Tenet 6)"
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
step_01_keys() {
    bash 01-keys.sh
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_pa() {
    # Build the pa-policies ConfigMap dynamically from Lab 4's Rego.
    kubectl --context "$KCTX" -n zta-policy create configmap pa-policies \
        --from-file=zta.authz.rego=../04-dynamic-policy/01-zta.authz.rego \
        --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-pa.yaml
    kubectl --context "$KCTX" -n zta-policy rollout status deploy/pa --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_opa_config() {
    # Substitute the public key into the template and write the generated yaml.
    # The placeholder __BUNDLE_SIGNER_PUB__ is on its own line under `key: |`,
    # so we must preserve indentation when inserting the multi-line PEM.
    local indent
    indent=$(grep '__BUNDLE_SIGNER_PUB__' 03-opa-config.yaml.tmpl \
             | sed 's/__BUNDLE_SIGNER_PUB__.*//')
    local pub_indented
    pub_indented=$(sed "s/^/$indent/" keys/bundle-signer.pub)
    awk -v key="$pub_indented" '
      $0 ~ /__BUNDLE_SIGNER_PUB__/ { print key; next }
      { print }
    ' 03-opa-config.yaml.tmpl > 03-opa-config.yaml

    # The opa-config ConfigMap was originally created by the bootstrap with
    # field-manager zta-bootstrap; the OPA Deployment's container args were
    # taken over by zta-lab04. This step deliberately rewrites both — the
    # whole point is to swap OPA from inline-policy mode to signed-bundle
    # mode. --force-conflicts transfers ownership cleanly.
    kubectl --context "$KCTX" apply "${SSA[@]}" --force-conflicts -f 03-opa-config.yaml
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_apply_opa() {
    kubectl --context "$KCTX" -n zta-policy rollout restart deploy/opa
    kubectl --context "$KCTX" -n zta-policy rollout status  deploy/opa --timeout=180s
    # Give OPA a few seconds to download and verify the first bundle.
    echo "Waiting 15 s for OPA to download and activate the signed bundle..."
    sleep 15
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_close_loop() {
    bash 05-close-loop.sh
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-keys"         step_01_keys
run_step "02-pa"           step_02_pa
run_step "03-opa-config"   step_03_opa_config
run_step "04-apply-opa"    step_04_apply_opa
run_step "05-close-loop"   step_05_close_loop

echo
echo "Lab 6 install completed successfully."

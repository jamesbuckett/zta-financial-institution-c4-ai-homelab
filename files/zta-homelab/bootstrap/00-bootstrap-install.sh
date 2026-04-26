#!/usr/bin/env bash
set -euo pipefail

ARCH="$(dpkg --print-architecture)"          # amd64 or arm64
BIN=/usr/local/bin
KCTX="docker-desktop"

# Every bootstrap manifest is applied with server-side apply so ownership is
# tracked per-field. This avoids the "failed to re-apply configuration after
# performing Server-Side Apply migration" warning when later labs (e.g. Lab 1
# backfill) run SSA against these objects.
SSA=(--server-side --field-manager=zta-bootstrap)

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
    echo ">>> ${CURRENT_STEP}"
    echo "    $*"
    echo "==============================================================="
    "$@"
    pause
}

run_step "00-namespaces"     kubectl --context "$KCTX" apply "${SSA[@]}" -f 00-namespaces.yaml
run_step "01-cert-manager"   ./01-cert-manager.sh
run_step "02-istio"          ./02-istio.sh
run_step "03-spire"          kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-spire.yaml
run_step "04-keycloak"       kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-keycloak.yaml
run_step "05-opa"            kubectl --context "$KCTX" apply "${SSA[@]}" -f 05-opa.yaml
run_step "06-gatekeeper"     ./06-gatekeeper.sh
run_step "07-falco"          ./07-falco.sh
run_step "08-observability"  ./08-observability.sh
step_09_bookstore() {
    # Apply the bookstore workloads, then wait for each to be Ready before
    # returning. Without this wait, control returns to the master installer
    # while the api/db/frontend pods are still Pending, and Lab 2's verify
    # races the api pod's startup when it port-forwards via
    # `istioctl proxy-config listener`.
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 09-bookstore.yaml
    kubectl --context "$KCTX" -n bookstore-frontend rollout status deployment/frontend --timeout=180s
    kubectl --context "$KCTX" -n bookstore-api      rollout status deployment/api      --timeout=180s
    kubectl --context "$KCTX" -n bookstore-data     rollout status statefulset/db      --timeout=180s
}
run_step "09-bookstore"      step_09_bookstore

echo
echo "All steps completed successfully."

#!/usr/bin/env bash
set -euo pipefail

ARCH="$(dpkg --print-architecture)"          # amd64 or arm64
BIN=/usr/local/bin
KCTX="docker-desktop"

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
    echo
    echo "==============================================================="
    echo ">>> ${CURRENT_STEP}"
    echo "    $*"
    echo "==============================================================="
    "$@"
    pause
}

run_step "00-namespaces"     kubectl --context "$KCTX" apply -f 00-namespaces.yaml
run_step "01-cert-manager"   ./01-cert-manager.sh
run_step "02-istio"          ./02-istio.sh
run_step "03-spire"          kubectl --context "$KCTX" apply -f 03-spire.yaml
run_step "04-keycloak"       kubectl --context "$KCTX" apply -f 04-keycloak.yaml
run_step "05-opa"            kubectl --context "$KCTX" apply -f 05-opa.yaml
run_step "06-gatekeeper"     ./06-gatekeeper.sh
run_step "07-falco"          ./07-falco.sh
run_step "08-observability"  ./08-observability.sh
run_step "09-bookstore"      kubectl --context "$KCTX" apply -f 09-bookstore.yaml

echo
echo "All steps completed successfully."

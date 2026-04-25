#!/usr/bin/env bash
# Lab 2 — Secured Comms (NIST SP 800-207 Tenet 2) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: every kubectl apply is idempotent under server-side apply.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab02)

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
    echo "==============================================================="
    "$@"
    pause
}

# ---------------------------------------------------------------------------
step_01_peer_authn_strict() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 01-peer-authn-strict.yaml
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_default_deny() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-default-deny.yaml
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_debug_pod() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-debug-pod.yaml
    kubectl --context "$KCTX" -n zta-lab-debug wait --for=condition=Ready pod/debug --timeout=60s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_plaintext_attempt() {
    # Designed failure: a successful plaintext call would mean STRICT mTLS is
    # not enforced. We disable -e around the curl so we can inspect the exit
    # code, then abort if it unexpectedly returned 0.
    set +e
    kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
        curl -sv --max-time 5 http://api.bookstore-api.svc.cluster.local/headers
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: plaintext call to api.bookstore-api unexpectedly succeeded (exit 0)."
        echo "STRICT mTLS is not being enforced — investigate before proceeding."
        return 1
    fi
    echo "OK: plaintext call refused as expected (curl exit=$rc)."
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_packet_capture() {
    # Drive a tcpdump in the debug pod while the frontend (with sidecar) calls
    # the api. The capture is piped to /tmp/capture.txt on the host so the
    # 05-verify.sh and 06-verify.sh can both inspect it.
    rm -f /tmp/capture.txt

    # tcpdump auto-terminates after 30 packets.
    kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
        tcpdump -i any -nn -s 0 -c 30 -A 'tcp port 80 or tcp port 15006' \
        > /tmp/capture.txt 2>&1 &
    local TCPDUMP_PID=$!

    # Give tcpdump time to attach.
    sleep 2

    # Drive 10 wget calls from the frontend pod (which has a sidecar).
    local FRONTEND
    FRONTEND=$(kubectl --context "$KCTX" -n bookstore-frontend get pod -l app=frontend -o name | head -1)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kubectl --context "$KCTX" -n bookstore-frontend exec "$FRONTEND" -c nginx -- \
            wget -qO- http://api.bookstore-api.svc.cluster.local/headers >/dev/null || true
        sleep 0.3
    done

    # Wait up to 15s for tcpdump to finish; kill it if it hangs.
    local waited=0
    while kill -0 "$TCPDUMP_PID" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 15 ]; then
            kill "$TCPDUMP_PID" 2>/dev/null || true
            break
        fi
    done
    wait "$TCPDUMP_PID" 2>/dev/null || true

    echo
    echo "--- /tmp/capture.txt (first 40 lines) ---"
    head -40 /tmp/capture.txt || true
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

step_06_istio_cross_check() {
    istioctl --context "$KCTX" authn tls-check \
        $(kubectl --context "$KCTX" -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2).bookstore-frontend \
        api.bookstore-api.svc.cluster.local
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-peer-authn-strict" step_01_peer_authn_strict
run_step "02-default-deny"      step_02_default_deny
run_step "03-debug-pod"         step_03_debug_pod
run_step "04-plaintext-attempt" step_04_plaintext_attempt
run_step "05-packet-capture"    step_05_packet_capture
run_step "06-istio-cross-check" step_06_istio_cross_check

echo
echo "Lab 2 install completed successfully."

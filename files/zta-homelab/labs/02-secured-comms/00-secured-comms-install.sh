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

LAB_TITLE="Lab 2 — Secured Comms (NIST SP 800-207 Tenet 2)"
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
    # The pod's hostNetwork field is immutable, so a re-run that's migrating
    # from a non-hostNetwork pod to a hostNetwork pod (or vice-versa) cannot
    # be done via `kubectl apply` alone. Recreate to keep the step idempotent.
    kubectl --context "$KCTX" -n zta-lab-debug delete pod debug \
        --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
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
    # Filter on tcp port 8080: that's the api Deployment's targetPort and the
    # destination port that appears on the wire (cni0 / veth) for traffic
    # leaving the frontend sidecar towards the api pod. The Service port (80)
    # never appears on the wire — it's resolved to an endpoint by kube-proxy
    # before egress. The Istio inbound listener (15006) isn't on the wire
    # either; it lives behind the api pod's iptables REDIRECT and is only
    # observable from inside the api pod's netns.
    # -X (hex + ASCII) is required so 05-verify.sh can grep for TLS record
    # bytes (1703 03... / 1603 03...) in the packet payload dump; -A would
    # only print printable ASCII.
    kubectl --context "$KCTX" -n zta-lab-debug exec debug -- \
        tcpdump -i any -nn -s 0 -c 30 -X 'tcp port 8080' \
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
    # `istioctl authn tls-check` was removed after 1.20. The modern equivalent
    # is two narrower probes that, taken together, prove the same end-to-end
    # mTLS posture:
    #   (a) the source pod's outbound cluster to api uses the Envoy TLS
    #       transport socket (replaces the old CLIENT=ISTIO_MUTUAL column),
    #   (b) the destination workload's effective PeerAuthentication mode is
    #       STRICT (replaces the old SERVER=STRICT column).
    local FRONTEND_POD API_POD
    FRONTEND_POD=$(kubectl --context "$KCTX" -n bookstore-frontend get pod -l app=frontend -o name | head -1 | cut -d/ -f2)
    API_POD=$(kubectl --context "$KCTX" -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)

    echo "Source outbound transport socket (frontend → api):"
    istioctl --context "$KCTX" proxy-config cluster -n bookstore-frontend "$FRONTEND_POD" \
        --fqdn api.bookstore-api.svc.cluster.local -o json \
        | jq -r '.[0].transportSocketMatches[0].transportSocket.name // "(none)"'

    echo
    echo "Destination effective PeerAuthentication mode (api):"
    istioctl --context "$KCTX" experimental describe pod -n bookstore-api "$API_POD" \
        | awk '/Workload mTLS mode:/ {print $NF}'

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

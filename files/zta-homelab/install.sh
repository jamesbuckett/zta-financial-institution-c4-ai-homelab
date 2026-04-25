#!/usr/bin/env bash
# ZTA homelab — master installer.
# Runs bootstrap and Labs 1-7 end-to-end on a clean docker-desktop cluster,
# with each lab's umbrella verify.sh gating the next one. Pauses inside the
# individual orchestrators are skipped via ZTA_NO_PAUSE=1 (use --pause to
# keep them).
#
# Usage: ./install.sh [--pause] [--skip-bootstrap] [--from N] [--verify-only] [--help]
#
# Idempotent: re-running against an already-installed cluster is a no-op
# (modulo rollout-status waits). Aborts on the first failed step or verify.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Defaults

PAUSE=0
SKIP_BOOTSTRAP=0
FROM=1
VERIFY_ONLY=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --pause              Keep the per-step pauses inside each lab (interactive).
  --skip-bootstrap     Assume bootstrap is already applied; skip it.
  --from N             Start at lab N (1-7). Skips bootstrap and labs < N.
  --verify-only        Run each lab's umbrella verify.sh; do NOT install.
  --help, -h           Print this help.

Examples:
  ./install.sh                       # full end-to-end install, no pauses
  ./install.sh --pause               # full install, with per-step pauses
  ./install.sh --skip-bootstrap      # bootstrap already done; install labs only
  ./install.sh --from 5              # install labs 5, 6, 7 only
  ./install.sh --verify-only         # check the cluster matches the lab specs
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --pause)            PAUSE=1; shift ;;
        --skip-bootstrap)   SKIP_BOOTSTRAP=1; shift ;;
        --from)
            FROM="${2:-}"
            if [ -z "$FROM" ]; then
                echo "Error: --from requires an integer argument 1..7" >&2
                exit 2
            fi
            shift 2
            ;;
        --verify-only)      VERIFY_ONLY=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if ! [[ "$FROM" =~ ^[1-7]$ ]]; then
    echo "Error: --from must be an integer 1..7 (got '$FROM')" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Pause control: master is non-interactive by default; --pause re-enables.

if [ "$PAUSE" = "0" ]; then
    export ZTA_NO_PAUSE=1
else
    unset ZTA_NO_PAUSE
fi

# ---------------------------------------------------------------------------
# Trap

CURRENT_STAGE="(start)"
on_error() {
    local rc=$?
    echo
    echo "==============================================================="
    echo "MASTER INSTALL FAILED at stage: ${CURRENT_STAGE} (exit ${rc})"
    echo "Fix the issue above, then re-run ./install.sh."
    echo "==============================================================="
    exit "$rc"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Lab table

LABS=(
    "01-resources:00-resources-install.sh"
    "02-secured-comms:00-secured-comms-install.sh"
    "03-per-session:00-per-session-install.sh"
    "04-dynamic-policy:00-dynamic-policy-install.sh"
    "05-posture-monitoring:00-posture-monitoring-install.sh"
    "06-strict-enforcement:00-strict-enforcement-install.sh"
    "07-telemetry-loop:00-telemetry-loop-install.sh"
)

# ---------------------------------------------------------------------------
# Banner

banner() {
    echo "==============================================================="
    echo ">>> $1"
    echo "==============================================================="
}

# ---------------------------------------------------------------------------
# Main

echo "==============================================================="
echo "ZTA homelab — master installer"
echo "  pause:           ${PAUSE} (0 = no pauses, 1 = interactive)"
echo "  skip-bootstrap:  ${SKIP_BOOTSTRAP}"
echo "  from:            lab ${FROM}"
echo "  verify-only:     ${VERIFY_ONLY}"
echo "==============================================================="
echo

# Bootstrap (skip if --skip-bootstrap, --from N>1, or --verify-only).
if [ "$VERIFY_ONLY" = "0" ] && [ "$SKIP_BOOTSTRAP" = "0" ] && [ "$FROM" = "1" ]; then
    CURRENT_STAGE="bootstrap"
    banner "Bootstrap (cluster prerequisites)"
    bash bootstrap/00-bootstrap-install.sh
    echo
    echo "Bootstrap complete."
    echo
fi

# Each lab: install (unless --verify-only) + umbrella verify.
for ((i = FROM; i <= 7; i++)); do
    entry="${LABS[$((i - 1))]}"
    dir="${entry%%:*}"
    install="${entry##*:}"
    lab_path="labs/${dir}"

    if [ "$VERIFY_ONLY" = "0" ]; then
        CURRENT_STAGE="lab ${i} install (${dir})"
        banner "Lab ${i} install — ${dir}"
        bash "${lab_path}/${install}"
        echo
    fi

    CURRENT_STAGE="lab ${i} verify (${dir})"
    banner "Lab ${i} verify — ${dir}"
    bash "${lab_path}/verify.sh"
    echo
done

# ---------------------------------------------------------------------------
# Done

if [ "$VERIFY_ONLY" = "1" ]; then
    echo "==============================================================="
    echo "All seven labs verified."
    echo "==============================================================="
else
    echo "==============================================================="
    echo "All seven labs installed and verified."
    echo "==============================================================="
fi

# Master install.sh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ZTA_NO_PAUSE` opt-out to all 8 existing orchestrators (1 bootstrap + 7 labs) and ship a single end-to-end installer at `files/zta-homelab/install.sh`.

**Architecture:** Two commits. Commit 1 patches the eight orchestrators with the same 3-line `pause()` opt-out (functionally a no-op when run interactively). Commit 2 creates `files/zta-homelab/install.sh` that exports `ZTA_NO_PAUSE=1` and chains bootstrap + labs.

**Spec:** `docs/superpowers/specs/2026-04-26-master-install-design.md`

**Tech Stack:** bash 5+. No new tooling.

---

## Pre-flight

- [ ] **Step P.1: Verify clean tree on main**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
git rev-parse --abbrev-ref HEAD
```
Expected: clean, `main`.

- [ ] **Step P.2: Verify the eight orchestrators all currently have the same pause() body**

```bash
grep -A4 '^pause()' \
  files/zta-homelab/bootstrap/00-bootstrap-install.sh \
  files/zta-homelab/labs/01-resources/00-resources-install.sh \
  files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh \
  files/zta-homelab/labs/03-per-session/00-per-session-install.sh \
  files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh \
  files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh \
  files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh \
  files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh
```
Expected: every file shows the same 4-line body — the `read -r -p "Step '${CURRENT_STEP}' complete..."` block.

---

### Task 1: Patch all eight orchestrators with `ZTA_NO_PAUSE` opt-out

**Files modified:**
- `files/zta-homelab/bootstrap/00-bootstrap-install.sh`
- `files/zta-homelab/labs/01-resources/00-resources-install.sh`
- `files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh`
- `files/zta-homelab/labs/03-per-session/00-per-session-install.sh`
- `files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh`
- `files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh`
- `files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh`
- `files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh`

In each of the eight files, replace the existing `pause()` function with the version that honours `ZTA_NO_PAUSE`.

- [ ] **Step 1: Apply identical edit to all eight files**

For each path above, replace this exact block:

```bash
pause() {
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}
```

with:

```bash
pause() {
    if [ "${ZTA_NO_PAUSE:-0}" = "1" ]; then
        return 0
    fi
    echo
    read -r -p "Step '${CURRENT_STEP}' complete. Press Enter to continue (Ctrl-C to abort)... " _
    echo
}
```

- [ ] **Step 2: Smoke-check every file still parses**

```bash
for f in \
  files/zta-homelab/bootstrap/00-bootstrap-install.sh \
  files/zta-homelab/labs/01-resources/00-resources-install.sh \
  files/zta-homelab/labs/02-secured-comms/00-secured-comms-install.sh \
  files/zta-homelab/labs/03-per-session/00-per-session-install.sh \
  files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh \
  files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh \
  files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh \
  files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 8 lines, all `OK`.

- [ ] **Step 3: Verify each file's `pause()` now contains the opt-out**

```bash
for f in \
  files/zta-homelab/bootstrap/00-bootstrap-install.sh \
  files/zta-homelab/labs/0[1-7]-*/00-*-install.sh; do
  grep -q 'ZTA_NO_PAUSE:-0' "$f" && echo "OK $f" || echo "MISSING $f"
done
```
Expected: 8 lines, all `OK`.

- [ ] **Step 4: Commit (single commit for all 8 patches)**

```bash
git add \
  files/zta-homelab/bootstrap/00-bootstrap-install.sh \
  files/zta-homelab/labs/0[1-7]-*/00-*-install.sh
git commit -m "$(cat <<'EOF'
Add ZTA_NO_PAUSE opt-out to all 8 orchestrators

Each pause() now returns immediately when ZTA_NO_PAUSE=1 is set in the
environment. The interactive flow when run individually is unchanged.
The master installer (next commit) sets ZTA_NO_PAUSE=1 so it can chain
bootstrap + 7 labs end-to-end without prompting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create `files/zta-homelab/install.sh`

**File:**
- Create: `files/zta-homelab/install.sh`

- [ ] **Step 1: Create the master install script**

```bash
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
        --from)             FROM="${2:-}"; shift 2 ;;
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
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/install.sh
chmod +x files/zta-homelab/install.sh
```
Expected: no output from `bash -n`; executable bit set.

- [ ] **Step 3: Sanity-check `--help`**

```bash
files/zta-homelab/install.sh --help
```
Expected: the usage block prints; exit 0.

- [ ] **Step 4: Sanity-check argument validation**

```bash
files/zta-homelab/install.sh --from 9 || echo "rc=$?"
files/zta-homelab/install.sh --frob   || echo "rc=$?"
```
Expected: both error out with exit 2.

- [ ] **Step 5: Commit and push**

```bash
git add files/zta-homelab/install.sh
git commit -m "$(cat <<'EOF'
Add ZTA homelab master install.sh

Single command that runs bootstrap + Labs 1-7 end-to-end on docker-desktop,
gating each lab on its umbrella verify.sh. Defaults to non-interactive
(via ZTA_NO_PAUSE=1); --pause re-enables per-step pauses; --skip-bootstrap,
--from N, and --verify-only trim or constrain the run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 3: Final smoke-check (controller runs this)

- [ ] **Step 1: List the master and confirm all eight orchestrators carry the opt-out**

```bash
ls -l files/zta-homelab/install.sh
for f in \
  files/zta-homelab/bootstrap/00-bootstrap-install.sh \
  files/zta-homelab/labs/0[1-7]-*/00-*-install.sh; do
  grep -q 'ZTA_NO_PAUSE:-0' "$f" && echo "OK $f" || echo "MISSING $f"
done
```
Expected: master is executable; all 8 lines `OK`.

- [ ] **Step 2: Confirm clean tree**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope

- Running the master against a real cluster. Smoke-checks here are syntax-only (`bash -n`) plus argument-validation. The first end-to-end run on a live cluster is the integration test; same situation as every prior lab.

## Self-review

**Spec coverage:**
- 8 orchestrators patched with the documented `pause()` body → Task 1. ✓
- `files/zta-homelab/install.sh` created with all four flags + help → Task 2. ✓
- Bootstrap inclusion (skipped if `--skip-bootstrap` or `--from N>1`) → Task 2 step 1, the `if [ "$VERIFY_ONLY" = "0" ] && [ "$SKIP_BOOTSTRAP" = "0" ] && [ "$FROM" = "1" ]` guard. ✓
- Each lab gated by its umbrella verify → Task 2 step 1, the for-loop. ✓
- Trap printing failed stage → Task 2 step 1, `on_error`. ✓
- Acceptance criteria 1–8 covered by Tasks 2 and 3 sanity checks. ✓

**Placeholder scan:** No "TBD".

**Type/identifier consistency:**
- `ZTA_NO_PAUSE`, `KCTX`, `SCRIPT_DIR`, `CURRENT_STAGE`, `FROM`, `LABS`, `lab_path`, `install` — same names everywhere they appear. ✓
- The LABS array entries match the on-disk lab directories and orchestrator filenames. ✓
- The trap is `on_error` (matches Lab 1-7 orchestrator naming). ✓

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check 2 (default-deny grep) is the only assertion that doesn't depend on the
# `opa` CLI; it's also the only one that catches the lab-critical regression
# (someone editing `default allow := false` to `:= true`). Run it
# unconditionally so a host without `opa` still gets a meaningful signal.
# Checks 1, 3, 3b are skipped with a clear note when `opa` is absent — the
# in-cluster OPA loads the same Rego at step 02 and exercises it for real
# at step 04 (three-requests), so local validation is convenience, not the
# system of record.
HAVE_OPA=0
if command -v opa >/dev/null 2>&1; then
  HAVE_OPA=1
fi

# 1. The .rego file parses — no syntax error, default-deny is wired.
printf '\n== 1. Rego parses cleanly ==\n'
if [ "$HAVE_OPA" = "1" ]; then
  opa parse "$SCRIPT_DIR/01-zta.authz.rego" >/dev/null && echo PARSED
else
  echo "SKIPPED: 'opa' CLI not on PATH (in-cluster OPA still validates at step 02)"
fi
# Expected: PARSED   (or SKIPPED if opa CLI is not installed)

# 2. Default-deny is the bottom of the rule lattice (T4 — fail-closed).
printf '\n== 2. default allow / decision are fail-closed ==\n'
grep -E '^default (allow|decision)' "$SCRIPT_DIR/01-zta.authz.rego"
# Expected:
#   default allow := false
#   default decision := {"allow": false, "reason": "default-deny"}

# 3. Unit-test against a fabricated input — trusted GET allows, tampered denies.
printf '\n== 3. trusted-GET evaluates allow=true ==\n'
if [ "$HAVE_OPA" = "1" ]; then
  opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
    --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"trusted"}}},"source":{"principal":"spiffe://cluster.local/ns/bookstore-frontend/sa/default"}}}') \
    'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.allow'
else
  echo "SKIPPED: 'opa' CLI not on PATH"
fi
# Expected: true

printf '\n== 3b. tampered evaluates reason=device-tampered ==\n'
if [ "$HAVE_OPA" = "1" ]; then
  opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
    --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"tampered"}}}}}') \
    'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.reason'
else
  echo "SKIPPED: 'opa' CLI not on PATH"
fi
# Expected: "device-tampered"

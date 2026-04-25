SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. The .rego file parses — no syntax error, default-deny is wired.
printf '\n== 1. Rego parses cleanly ==\n'
opa parse "$SCRIPT_DIR/01-zta.authz.rego" >/dev/null && echo PARSED
# Expected: PARSED

# 2. Default-deny is the bottom of the rule lattice (T4 — fail-closed).
printf '\n== 2. default allow / decision are fail-closed ==\n'
grep -E '^default (allow|decision)' "$SCRIPT_DIR/01-zta.authz.rego"
# Expected:
#   default allow := false
#   default decision := {"allow": false, "reason": "default-deny"}

# 3. Unit-test against a fabricated input — trusted GET allows, tampered denies.
printf '\n== 3. trusted-GET evaluates allow=true ==\n'
opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
  --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"trusted"}}},"source":{"principal":"spiffe://cluster.local/ns/bookstore-frontend/sa/default"}}}') \
  'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.allow'
# Expected: true

printf '\n== 3b. tampered evaluates reason=device-tampered ==\n'
opa eval -d "$SCRIPT_DIR/01-zta.authz.rego" \
  --input <(printf '%s' '{"attributes":{"request":{"http":{"method":"GET","path":"/anything","headers":{"authorization":"Bearer eyJ.eyJzdWIiOiJhbGljZSJ9.","x-device-posture":"tampered"}}}}}') \
  'data.zta.authz.decision' --format=json | jq '.result[0].expressions[0].value.reason'
# Expected: "device-tampered"

package zta.authz

import rego.v1

# Envoy ext_authz input shape:
#   input.attributes.request.http.{method,path,headers}
#   input.attributes.source.principal          -- SPIFFE peer URI
#   input.parsed_path, input.parsed_query

default allow := false
default decision := {"allow": false, "reason": "default-deny"}

# --- helpers --------------------------------------------------------
token := t if {
  auth := input.attributes.request.http.headers.authorization
  startswith(auth, "Bearer ")
  t := substring(auth, 7, -1)
}

claims := c if {
  [_, payload, _] := io.jwt.decode(token)
  c := payload
}

posture := p if {
  p := input.attributes.request.http.headers["x-device-posture"]
} else := "unknown"

method := m if { m := input.attributes.request.http.method }
path   := p if { p := input.attributes.request.http.path }

workload_peer := s if { s := input.attributes.source.principal }

# Helper: the "unknown posture + write method" combination, used as a
# negative guard in the residual deny rules below. Rego v1 doesn't accept
# `and` in expressions, so the combo is factored into a partial rule.
unknown_write_combo if {
  posture == "unknown"
  method != "GET"
}

# --- rules ----------------------------------------------------------
# Allow: authenticated user + trusted posture + known workload peer
allow if {
  claims.sub
  posture == "trusted"
  startswith(workload_peer, "spiffe://cluster.local/ns/")
}

# Allow read-only GET from suspect devices
allow if {
  method == "GET"
  claims.sub
  posture == "suspect"
}

# Decision rules — Rego v1 complete-rule semantics require AT MOST one
# non-default decision per input. Each branch carries explicit guards
# (`not allow`, `not token`, `not claims.sub`) so they're mutually
# exclusive — without these guards, e.g. a tampered request with a valid
# token matches both `device-tampered` and `no-matching-allow` and OPA
# crashes with eval_conflict_error: "complete rules must not produce
# multiple outputs". The default `decision := default-deny` handles the
# residual "no rule matched" case (e.g. the empty-input probe in 02-verify).
decision := {"allow": true, "reason": "ok"} if allow

decision := {"allow": false, "reason": "device-tampered"} if {
  posture == "tampered"
  not allow
}

decision := {"allow": false, "reason": "posture-unknown-on-write"} if {
  posture == "unknown"
  method != "GET"
  not allow
  posture != "tampered"
}

# Refinement (Lab 7): split the catch-all 'no-matching-allow' into three
# more-specific reasons so operators see a faster fix path.
decision := {"allow": false, "reason": "missing-token"}     if {
  not token
  not allow
  posture != "tampered"
  not unknown_write_combo
}
decision := {"allow": false, "reason": "invalid-subject"}   if {
  token
  not claims.sub
  not allow
  posture != "tampered"
  not unknown_write_combo
}
decision := {"allow": false, "reason": "no-matching-allow"} if {
  token
  claims.sub
  not allow
  posture != "tampered"
  not unknown_write_combo
}

# Final response Envoy expects
result := {
  "allowed": decision.allow,
  "headers": {
    "x-zta-decision-id": decision_id,
    "x-zta-decision-reason": decision.reason,
  },
  "body": body,
  "http_status": status,
}

status := 200 if decision.allow
status := 403 if not decision.allow

body := "" if decision.allow
body := sprintf(`{"error":"forbidden","reason":"%s","decision_id":"%s"}`, [decision.reason, decision_id]) if not decision.allow

decision_id := crypto.sha256(sprintf("%v|%v|%v|%v|%v",
  [claims.sub, method, path, posture, time.now_ns()]))

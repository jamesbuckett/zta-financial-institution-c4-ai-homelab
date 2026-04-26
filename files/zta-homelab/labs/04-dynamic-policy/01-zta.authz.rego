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

# Decision rules — Rego v1 complete-rule semantics require that for any given
# input AT MOST ONE non-default rule produces a value. Each branch below
# guards itself against the others (e.g. the tampered branch carries
# `not allow`) so they're mutually exclusive. The previous version had a
# `decision := no-matching-allow if not allow` catch-all that always fired
# alongside the more specific deny rules and crashed OPA with
#   eval_conflict_error: complete rules must not produce multiple outputs
# which Envoy then surfaces as a bare 403 (no headers, no body).
#
# The default `decision := default-deny` handles the residual "no rule
# matched" case (e.g. an empty probe input, or a suspect POST that doesn't
# fit any specific deny class).
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

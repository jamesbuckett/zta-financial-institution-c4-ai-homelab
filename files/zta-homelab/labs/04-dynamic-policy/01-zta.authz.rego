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

# Hard deny if device is tampered, regardless of token
decision := {"allow": false, "reason": "device-tampered"} if {
  posture == "tampered"
}

# Deny if unknown posture AND write method
decision := {"allow": false, "reason": "posture-unknown-on-write"} if {
  posture == "unknown"
  method != "GET"
}

# If a narrow deny rule didn't fire, project `allow` to decision
decision := {"allow": true,  "reason": "ok"}                    if allow
decision := {"allow": false, "reason": "no-matching-allow"}     if not allow

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

#!/usr/bin/env bash
# Lab 7 — Telemetry Loop (NIST SP 800-207 Tenet 7).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion.
set -euo pipefail
CTX=${CTX:-docker-desktop}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PF_PID=""
trap '[ -n "$PF_PID" ] && kill $PF_PID 2>/dev/null' EXIT

pass=0; fail=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n' "$label"; fail=$((fail+1))
  fi
}
section() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
section "Step 01 — OPA metrics + ServiceMonitor"

check "opa-metrics Service exposes 8282" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-policy get svc opa-metrics \
                  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}')\" = '8282/8282' ]"

check "ServiceMonitor opa has release=kube-prom label" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-observability get servicemonitor opa \
                  -o jsonpath='{.metadata.labels.release}')\" = 'kube-prom' ]"

# OPA's distroless image has no wget/curl. Bridge via a port-forward and
# probe /metrics from the host. OPA 0.68's diagnostic /metrics endpoint
# does not emit any opa_-prefixed Prometheus series — process and request
# metrics are go_* and http_*. Use http_request_duration_seconds as the
# proof-of-life (same series the lab 7 ServiceMonitor tells Prometheus to
# scrape).
check "OPA /metrics returns at least one http_request_duration_seconds counter" \
  bash -c "
    kubectl --context $CTX -n zta-policy port-forward deploy/opa 18282:8282 >/dev/null 2>&1 &
    pf=\$!
    for _ in \$(seq 1 20); do
      curl -s --max-time 1 http://localhost:18282/health >/dev/null 2>&1 && break
      sleep 0.5
    done
    n=\$(curl -s http://localhost:18282/metrics | grep -c '^http_request_duration_seconds' || true)
    kill \$pf 2>/dev/null || true
    [ \"\$n\" -ge 1 ]
  "

# ---------------------------------------------------------------------------
section "Step 02 — Grafana Agent"

check "grafana-agent DaemonSet ready count == node count" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-observability get ds grafana-agent \
                  -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context $CTX get nodes --no-headers | wc -l | tr -d ' ')\" ]"

check "Agent config Loki URL is the cluster service" \
  bash -c "kubectl --context $CTX -n zta-observability get cm grafana-agent-config \
            -o jsonpath='{.data.agent\\.yaml}' \
            | yq -r '.logs.configs[0].clients[0].url' \
            | grep -qx 'http://loki.zta-observability.svc.cluster.local:3100/loki/api/v1/push'"

check "pipeline promotes decision_id, allow, reason" \
  bash -c "labels=\$(kubectl --context $CTX -n zta-observability get cm grafana-agent-config \
                    -o jsonpath='{.data.agent\\.yaml}' \
                    | yq -r '.logs.configs[0].scrape_configs[0].pipeline_stages[1].labels | keys | .[]') && \
           echo \"\$labels\" | grep -qx decision_id && \
           echo \"\$labels\" | grep -qx allow && \
           echo \"\$labels\" | grep -qx reason"

# ---------------------------------------------------------------------------
section "Step 03 — Istio tracing"

check "Telemetry mesh-default has otel-tempo at 100% sampling" \
  bash -c "[ \"\$(kubectl --context $CTX -n istio-system get telemetry mesh-default \
                  -o jsonpath='{.spec.tracing[0].providers[0].name}/{.spec.tracing[0].randomSamplingPercentage}')\" = 'otel-tempo/100' ]"

check "mesh config registers BOTH opa-ext-authz and otel-tempo" \
  bash -c "names=\$(kubectl --context $CTX -n istio-system get cm istio \
                    -o jsonpath='{.data.mesh}' | yq -r '.extensionProviders[].name' | sort | tr '\\n' ',') && \
           [ \"\$names\" = 'opa-ext-authz,otel-tempo,' ]"

# ---------------------------------------------------------------------------
section "Step 04 — Grafana dashboard"

check "zta-dashboard ConfigMap has grafana_dashboard=1 label" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-observability get cm zta-dashboard \
                  -o jsonpath='{.metadata.labels.grafana_dashboard}')\" = '1' ]"

check "dashboard JSON has exactly 4 panels" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-observability get cm zta-dashboard \
                  -o jsonpath='{.data.zta\\.json}' | jq '.panels | length')\" = '4' ]"

check "dashboard uid is zta-main" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-observability get cm zta-dashboard \
                  -o jsonpath='{.data.zta\\.json}' | jq -r '.uid')\" = 'zta-main' ]"

# ---------------------------------------------------------------------------
section "Step 05 — load mix produced telemetry signal"

# Note: relies on Loki containing recent OPA decisions. The umbrella does not
# port-forward Loki — it asserts via OPA logs as a proxy for "telemetry is flowing".
check "OPA log has events for trusted, suspect, and tampered postures in last 10m" \
  bash -c "logs=\$(kubectl --context $CTX -n zta-policy logs deploy/opa --since=10m) && \
           postures=\$(echo \"\$logs\" | jq -r 'select(.decision_id) | .input.attributes.request.http.headers[\"x-device-posture\"] // empty' | sort -u) && \
           echo \"\$postures\" | grep -qx trusted && \
           echo \"\$postures\" | grep -qx suspect && \
           echo \"\$postures\" | grep -qx tampered"

# ---------------------------------------------------------------------------
section "Step 06 — refined Rego published"

check "pa-policies ConfigMap contains 'missing-token' reason" \
  bash -c "kubectl --context $CTX -n zta-policy get cm pa-policies \
            -o jsonpath='{.data.zta\\.authz\\.rego}' | grep -q '\"missing-token\"'"

check "pa-policies ConfigMap contains 'invalid-subject' reason" \
  bash -c "kubectl --context $CTX -n zta-policy get cm pa-policies \
            -o jsonpath='{.data.zta\\.authz\\.rego}' | grep -q '\"invalid-subject\"'"

# /v1/status (REST 8181) requires opa-config to declare `status: console: true`
# (Lab 6's template does). The diagnostic-port /status (8282) is 404. Bridge
# via port-forward because OPA's image has no shell.
check "OPA /v1/status: bundle activated within last 10 minutes" \
  bash -c "
    kubectl --context $CTX -n zta-policy port-forward svc/opa 18181:8181 >/dev/null 2>&1 &
    pf=\$!
    for _ in \$(seq 1 20); do
      curl -s --max-time 1 http://localhost:18181/health >/dev/null 2>&1 && break
      sleep 0.5
    done
    out=\$(curl -s http://localhost:18181/v1/status)
    kill \$pf 2>/dev/null || true
    act=\$(echo \"\$out\" | jq -r '.result.bundles.zta.last_successful_activation')
    ts=\$(date -u -d \"\$act\" +%s 2>/dev/null)
    now=\$(date -u +%s)
    [ \$((now - ts)) -lt 600 ]
  "

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 7 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

# Lab 7 — Telemetry Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Lab 7's snippets from `index.html` (lines 6201–6853) into runnable scripts and manifests following the established Lab 1–6 pattern.

**Architecture:** Files in `files/zta-homelab/labs/07-telemetry-loop/`. Five YAMLs, four bash scripts (load mix, refined Rego rebuild via the orchestrator, break-it, orchestrator), six narrative verifies, umbrella verify.

**Tech Stack:** bash 5+, kubectl, jq, yq, curl, awk. Cluster: bootstrap-installed kube-prometheus-stack (release=kube-prom), Loki, Tempo, Grafana in `zta-observability`, plus everything from Labs 1–6.

**Spec:** `docs/superpowers/specs/2026-04-26-lab-7-telemetry-loop-design.md`

**Pattern reference:**
- `files/zta-homelab/labs/06-strict-enforcement/00-strict-enforcement-install.sh`
- `files/zta-homelab/labs/06-strict-enforcement/verify.sh`

**Important pattern note:** Per-step verify scripts are *narrative* (printf headings, kubectl/curl verbatim, `# Expected:` comments — no `set -e`, no shebang, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script using the `check` helper.

---

## File Structure

All files in `files/zta-homelab/labs/07-telemetry-loop/`:

```
01-opa-servicemonitor.yaml
01-verify.sh
02-grafana-agent.yaml
02-verify.sh
03-istio-tracing.yaml
03-verify.sh
04-dashboard.yaml
04-verify.sh
05-load-mix.sh
05-verify.sh
06-zta.authz.rego               # Refined policy (full file, not a diff)
06-verify.sh
07-break-it.sh
00-telemetry-loop-install.sh
verify.sh
```

---

## Pre-flight

- [ ] **Step P.1: Clean tree on main, spec present, lab dir empty**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
ls -l docs/superpowers/specs/2026-04-26-lab-7-telemetry-loop-design.md
ls files/zta-homelab/labs/07-telemetry-loop/
```
Expected: clean, on `main`, spec present, lab dir empty.

---

### Task 1: Step 01 — OPA ServiceMonitor

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/01-opa-servicemonitor.yaml`
- Create: `files/zta-homelab/labs/07-telemetry-loop/01-verify.sh`

- [ ] **Step 1: Create `01-opa-servicemonitor.yaml`** (verbatim from index.html line 6354)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: opa-metrics
  namespace: zta-policy
  labels: { app: opa }
spec:
  selector: { app: opa }
  ports: [{ name: metrics, port: 8282, targetPort: 8282 }]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: opa
  namespace: zta-observability
  labels: { release: kube-prom }
spec:
  namespaceSelector: { matchNames: ["zta-policy"] }
  selector: { matchLabels: { app: opa } }
  endpoints:
  - port: metrics
    path: /metrics
    interval: 15s
```

- [ ] **Step 2: Create `01-verify.sh`** (verbatim from index.html line 6389; with port-forward cleanup trap)

```bash
trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. opa-metrics Service exposes diagnostic port 8282 with selector app=opa.
printf '\n== 1. opa-metrics Service exposes 8282 with selector app=opa ==\n'
kubectl --context docker-desktop -n zta-policy get svc opa-metrics \
  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}{" sel="}{.spec.selector.app}{"\n"}'
# Expected: 8282/8282 sel=opa

printf '\n== 1b. opa-metrics endpoints populated ==\n'
kubectl --context docker-desktop -n zta-policy get endpoints opa-metrics \
  -o jsonpath='{.subsets[0].addresses[*].ip}{"\n"}' | wc -w
# Expected: >= 1

# 2. ServiceMonitor exists and matches the kube-prom release label.
printf '\n== 2. ServiceMonitor opa has release=kube-prom label ==\n'
kubectl --context docker-desktop -n zta-observability get servicemonitor opa \
  -o jsonpath='{.metadata.labels.release}{"\n"}'
# Expected: kube-prom

# 3. Prometheus has discovered OPA as an active target (port-forward Prom first).
printf '\n== 3. Prometheus reports OPA target health=up ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/kube-prom-kube-prome-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '[.data.activeTargets[] | select(.labels.job=="opa") | .health] | unique'
# Expected: ["up"]
kill $PF_PID 2>/dev/null
unset PF_PID

# 4. Metrics actually contain the OPA decision counter.
printf '\n== 4. OPA /metrics contains opa_* lines ==\n'
OPA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=opa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- http://localhost:8282/metrics | grep -c '^opa_'
# Expected: >= 1
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/01-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/01-verify.sh
yq eval '.' files/zta-homelab/labs/07-telemetry-loop/01-opa-servicemonitor.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/01-opa-servicemonitor.yaml \
        files/zta-homelab/labs/07-telemetry-loop/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 01 — OPA ServiceMonitor + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 02 — Grafana Agent (logs → Loki)

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/02-grafana-agent.yaml`
- Create: `files/zta-homelab/labs/07-telemetry-loop/02-verify.sh`

- [ ] **Step 1: Create `02-grafana-agent.yaml`** (verbatim from index.html line 6423)

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: grafana-agent-config, namespace: zta-observability }
data:
  agent.yaml: |
    logs:
      configs:
      - name: default
        positions: { filename: /tmp/positions.yaml }
        clients:
        - url: http://loki.zta-observability.svc.cluster.local:3100/loki/api/v1/push
        scrape_configs:
        - job_name: opa-decisions
          kubernetes_sd_configs: [{ role: pod }]
          relabel_configs:
          - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_label_app]
            regex: "zta-policy;opa"
            action: keep
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          pipeline_stages:
          - json:
              expressions:
                decision_id: decision_id
                allow: result.allowed
                reason: 'result.headers["x-zta-decision-reason"]'
                path:   input.attributes.request.http.path
                method: input.attributes.request.http.method
                posture: 'input.attributes.request.http.headers["x-device-posture"]'
          - labels:
              decision_id:
              allow:
              reason:
              path:
              method:
              posture:
---
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: grafana-agent, namespace: zta-observability }
spec:
  selector: { matchLabels: { app: grafana-agent } }
  template:
    metadata: { labels: { app: grafana-agent } }
    spec:
      serviceAccountName: default
      containers:
      - name: agent
        image: grafana/agent:v0.43.4
        args: ["-config.file=/etc/agent/agent.yaml"]
        volumeMounts:
        - { name: config, mountPath: /etc/agent }
        - { name: varlog, mountPath: /var/log, readOnly: true }
      volumes:
      - { name: config, configMap: { name: grafana-agent-config } }
      - { name: varlog, hostPath: { path: /var/log } }
```

- [ ] **Step 2: Create `02-verify.sh`** (verbatim from index.html line 6494; with cleanup trap)

```bash
trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. DaemonSet runs on every node.
printf '\n== 1. grafana-agent DS ready count == node count ==\n'
NODES=$(kubectl --context docker-desktop get nodes --no-headers | wc -l)
READY=$(kubectl --context docker-desktop -n zta-observability get ds grafana-agent \
          -o jsonpath='{.status.numberReady}')
echo "nodes=$NODES ready=$READY"
# Expected: nodes equals ready

# 2. Agent config targets the Loki cluster service and parses to a single client URL.
printf '\n== 2. Agent config Loki URL is the cluster service ==\n'
kubectl --context docker-desktop -n zta-observability get cm grafana-agent-config \
  -o jsonpath='{.data.agent\.yaml}' \
  | yq -r '.logs.configs[0].clients[0].url'
# Expected: http://loki.zta-observability.svc.cluster.local:3100/loki/api/v1/push

# 3. Pipeline stage extracts decision_id, allow, reason as Loki labels.
printf '\n== 3. Pipeline stage promotes decision_id, allow, reason to labels ==\n'
kubectl --context docker-desktop -n zta-observability get cm grafana-agent-config \
  -o jsonpath='{.data.agent\.yaml}' \
  | yq -r '.logs.configs[0].scrape_configs[0].pipeline_stages[1].labels | keys | .[]'
# Expected (any order, must include all three):
#   decision_id
#   allow
#   reason

# 4. Loki is reachable and reports zta-policy as a discovered namespace label.
printf '\n== 4. Loki reports a namespace label ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq -r '.data | .[]' | grep -c '^namespace$'
# Expected: 1
kill $PF_PID 2>/dev/null
unset PF_PID
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/02-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/02-verify.sh
yq eval '.' files/zta-homelab/labs/07-telemetry-loop/02-grafana-agent.yaml >/dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/02-grafana-agent.yaml \
        files/zta-homelab/labs/07-telemetry-loop/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 02 — Grafana Agent (OPA logs to Loki)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 03 — Istio tracing → Tempo

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/03-istio-tracing.yaml`
- Create: `files/zta-homelab/labs/07-telemetry-loop/03-verify.sh`

- [ ] **Step 1: Create `03-istio-tracing.yaml`** (verbatim from index.html line 6529; istio configmap explicitly preserves both providers)

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: { name: mesh-default, namespace: istio-system }
spec:
  tracing:
  - providers: [{ name: otel-tempo }]
    randomSamplingPercentage: 100
---
# CAVEAT: this rewrites the istio-system/istio configmap's mesh: key. We
# explicitly include BOTH extension providers so Lab 4's opa-ext-authz
# wiring survives the apply. If bootstrap had other top-level keys in
# this configmap (meshNetworks, defaultProviders, etc.), they may be
# lost. See spec for risk note.
apiVersion: v1
kind: ConfigMap
metadata: { name: istio, namespace: istio-system }
data:
  mesh: |
    extensionProviders:
    - name: opa-ext-authz
      envoyExtAuthzGrpc:
        service: opa.zta-policy.svc.cluster.local
        port: 9191
    - name: otel-tempo
      opentelemetry:
        service: tempo.zta-observability.svc.cluster.local
        port: 4317
```

- [ ] **Step 2: Create `03-verify.sh`** (verbatim from index.html line 6564; SCRIPT_DIR-relative `.env`; cleanup trap)

```bash
trap 'kill $PF_PID 2>/dev/null' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Telemetry resource exists at mesh root with otel-tempo provider and 100% sampling.
printf '\n== 1. Telemetry mesh-default has otel-tempo at 100%% sampling ==\n'
kubectl --context docker-desktop -n istio-system get telemetry mesh-default \
  -o jsonpath='{.spec.tracing[0].providers[0].name}/{.spec.tracing[0].randomSamplingPercentage}{"\n"}'
# Expected: otel-tempo/100

# 2. Mesh config registers BOTH extension providers (opa-ext-authz preserved + otel-tempo added).
printf '\n== 2. Mesh config has BOTH opa-ext-authz and otel-tempo ==\n'
kubectl --context docker-desktop -n istio-system get cm istio \
  -o jsonpath='{.data.mesh}' \
  | yq -r '.extensionProviders[].name' | sort
# Expected:
#   opa-ext-authz
#   otel-tempo

# 3. Make a request and confirm the api sidecar emits an OTel trace export.
printf '\n== 3. Tempo records traces from istio-ingressgateway ==\n'
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)
curl -s -o /dev/null -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  -H 'x-device-posture: trusted' http://localhost/api/headers
sleep 5

kubectl --context docker-desktop -n zta-observability port-forward svc/tempo 3200:3200 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -s 'http://localhost:3200/api/search?tags=service.name=istio-ingressgateway&limit=5' \
  | jq '.traces | length'
# Expected: >= 1
kill $PF_PID 2>/dev/null
unset PF_PID
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/03-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/03-verify.sh
yq eval '.' files/zta-homelab/labs/07-telemetry-loop/03-istio-tracing.yaml >/dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/03-istio-tracing.yaml \
        files/zta-homelab/labs/07-telemetry-loop/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 03 — Istio tracing to Tempo

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 04 — Grafana dashboard ConfigMap

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/04-dashboard.yaml`
- Create: `files/zta-homelab/labs/07-telemetry-loop/04-verify.sh`

- [ ] **Step 1: Create `04-dashboard.yaml`** (verbatim from index.html line 6603)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: zta-dashboard
  namespace: zta-observability
  labels: { grafana_dashboard: "1" }
data:
  zta.json: |
    {
      "title": "ZTA — Decisions, Latency, Drift (800-207 8.6 SLOs)",
      "uid": "zta-main",
      "schemaVersion": 38,
      "timezone": "browser",
      "panels": [
        { "title": "Decision rate (allow / deny / step-up)",
          "type": "timeseries",
          "gridPos": {"h":8,"w":12,"x":0,"y":0},
          "targets": [
            { "expr": "sum by (decision) (rate(http_request_duration_seconds_count{job=~\"opa.*\"}[5m]))" }
          ] },
        { "title": "Decision latency P50 / P99 (ms)",
          "type": "timeseries",
          "gridPos": {"h":8,"w":12,"x":12,"y":0},
          "targets": [
            { "expr": "1000 * histogram_quantile(0.5,  sum by (le) (rate(http_request_duration_seconds_bucket{job=~\"opa.*\"}[5m])))" },
            { "expr": "1000 * histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=~\"opa.*\"}[5m])))" }
          ] },
        { "title": "Deny reasons — last 1h",
          "type": "bargauge",
          "gridPos": {"h":8,"w":12,"x":0,"y":8},
          "targets": [
            { "expr": "sum by (reason) (count_over_time({namespace=\"zta-policy\", allow=\"false\"} | json [1h]))", "datasource": {"type":"loki"} }
          ] },
        { "title": "Recent denies (decision_id, path, posture, reason)",
          "type": "logs",
          "gridPos": {"h":8,"w":12,"x":12,"y":8},
          "targets": [
            { "expr": "{namespace=\"zta-policy\", allow=\"false\"} | json", "datasource": {"type":"loki"} }
          ] }
      ]
    }
```

- [ ] **Step 2: Create `04-verify.sh`** (verbatim from index.html line 6656; cleanup trap)

```bash
trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. ConfigMap carries the grafana_dashboard label so the sidecar provisioner picks it up.
printf '\n== 1. zta-dashboard ConfigMap has grafana_dashboard=1 label ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.metadata.labels.grafana_dashboard}{"\n"}'
# Expected: 1

# 2. Embedded JSON parses and declares exactly four panels with Tenet-7-aligned titles.
printf '\n== 2. Embedded JSON has exactly 4 panels ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.data.zta\.json}' | jq '.panels | length'
# Expected: 4

printf '\n== 2b. Panel titles ==\n'
kubectl --context docker-desktop -n zta-observability get cm zta-dashboard \
  -o jsonpath='{.data.zta\.json}' | jq -r '.panels[].title'
# Expected (any order):
#   Decision rate (allow / deny / step-up)
#   Decision latency P50 / P99 (ms)
#   Deny reasons — last 1h
#   Recent denies (decision_id, path, posture, reason)

# 3. Grafana has registered the dashboard under uid 'zta-main'.
printf '\n== 3. Grafana has dashboard uid=zta-main ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/kube-prom-grafana 3000:80 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -su admin:admin http://localhost:3000/api/dashboards/uid/zta-main \
  | jq -r '.dashboard.title // "missing"'
# Expected: ZTA — Decisions, Latency, Drift (800-207 8.6 SLOs)
kill $PF_PID 2>/dev/null
unset PF_PID
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/04-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/04-verify.sh
yq eval '.' files/zta-homelab/labs/07-telemetry-loop/04-dashboard.yaml >/dev/null && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/04-dashboard.yaml \
        files/zta-homelab/labs/07-telemetry-loop/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 04 — Grafana dashboard ConfigMap

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 05 — load mix + verify

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/05-load-mix.sh`
- Create: `files/zta-homelab/labs/07-telemetry-loop/05-verify.sh`

- [ ] **Step 1: Create `05-load-mix.sh`** (verbatim from index.html line 6688; SCRIPT_DIR-relative `.env`)

```bash
#!/usr/bin/env bash
# Drive a 200-request load mix across (posture × method) so the dashboard
# panels have signal. Mostly trusted GETs with a trickle of suspect POSTs
# and the occasional tampered request — matches the source 5 flow.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

for i in $(seq 1 200); do
  POSTURES=(trusted trusted trusted trusted suspect suspect tampered)
  METHODS=(GET GET GET GET POST)
  P=${POSTURES[$((RANDOM % 7))]}
  M=${METHODS[$((RANDOM % 5))]}
  curl -s -o /dev/null -X $M \
    -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
    -H "x-device-posture: $P" \
    http://localhost/api/anything &
  if [ $((i % 20)) -eq 0 ]; then wait; fi
done
wait
echo "load mix complete"
```

- [ ] **Step 2: Create `05-verify.sh`** (verbatim from index.html line 6722; cleanup trap)

```bash
trap 'kill $PF_PID 2>/dev/null' EXIT

# 1. The load mix produced >= 200 OPA decisions in the last 5 minutes.
printf '\n== 1. >=200 OPA decisions in last 5 minutes ==\n'
kubectl --context docker-desktop -n zta-policy port-forward svc/kube-prom-kube-prome-prometheus 9090:9090 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(increase(http_request_duration_seconds_count{job=~"opa.*"}[5m]))' \
  | jq '.data.result[0].value[1] | tonumber'
# Expected: >= 200
kill $PF_PID 2>/dev/null
unset PF_PID

# 2. All three posture values appear in Loki (proves the dashboard's deny-reasons panel has signal).
printf '\n== 2. Loki has events for trusted, suspect, and tampered postures ==\n'
kubectl --context docker-desktop -n zta-observability port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
for P in trusted suspect tampered; do
  N=$(curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
    --data-urlencode "query={namespace=\"zta-policy\", posture=\"$P\"}" \
    --data-urlencode "start=$(date -u -d '-10 min' +%s)000000000" \
    --data-urlencode "end=$(date -u +%s)000000000" \
    | jq '[.data.result[].values[] | length] | add // 0')
  echo "$P=$N"
done
# Expected: trusted > 0, suspect > 0, tampered > 0

# 3. P99 decision latency is below the 800-207 8.6 SLO ceiling of 10 ms.
printf '\n== 3. P99 decision latency < 10 ms ==\n'
P99=$(curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=1000 * histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=~"opa.*"}[5m])))' \
  2>/dev/null | jq -r '.data.result[0].value[1] // "0"')
echo "P99_ms=$P99"
# Expected: P99_ms < 10
kill $PF_PID 2>/dev/null
unset PF_PID
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/05-load-mix.sh
bash -n files/zta-homelab/labs/07-telemetry-loop/05-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/05-load-mix.sh \
        files/zta-homelab/labs/07-telemetry-loop/05-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/05-load-mix.sh \
        files/zta-homelab/labs/07-telemetry-loop/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 05 — load mix + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Step 06 — refined Rego + verify

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/06-zta.authz.rego`
- Create: `files/zta-homelab/labs/07-telemetry-loop/06-verify.sh`

- [ ] **Step 1: Create `06-zta.authz.rego`** — full Lab 4 Rego with the catch-all line replaced by three rules per the doc's diff at line 6757.

```rego
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

# If a narrow deny rule didn't fire, project `allow` to decision.
# Refinement (Lab 7): split the previous catch-all 'no-matching-allow'
# into three more-specific reasons so operators see a faster fix path.
decision := {"allow": true,  "reason": "ok"}                    if allow
decision := {"allow": false, "reason": "missing-token"}         if not token
decision := {"allow": false, "reason": "invalid-subject"}       if { token; not claims.sub }
decision := {"allow": false, "reason": "no-matching-allow"}     if { token; claims.sub; not allow }

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
```

- [ ] **Step 2: Create `06-verify.sh`** (from index.html line 6770 with `kubectl exec` for OPA `/status`)

```bash
# 1. Refined Rego is in the PA ConfigMap and lists the new reasons.
printf '\n== 1. PA ConfigMap contains the new reason strings ==\n'
kubectl --context docker-desktop -n zta-policy get cm pa-policies \
  -o jsonpath='{.data.zta\.authz\.rego}' | grep -E '"missing-token"|"invalid-subject"' | wc -l
# Expected: 2

# 2. PA rebuilt the bundle and OPA picked it up (last_successful_activation is recent).
printf '\n== 2. OPA last_successful_activation is recent (<60s) ==\n'
STATUS=$(kubectl --context docker-desktop -n zta-policy exec deploy/opa -- \
  wget -qO- http://localhost:8282/status 2>/dev/null)
ACT=$(echo "$STATUS" | jq -r '.bundles.zta.last_successful_activation')
NOW=$(date -u +%s); ACT_TS=$(date -u -d "$ACT" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S%Z' "$ACT" +%s 2>/dev/null)
echo "act_age_s=$((NOW - ACT_TS))"
# Expected: act_age_s < 60

# 3. Send a request with NO Authorization header — reason should now be 'missing-token',
#    not the old catch-all 'no-matching-allow'.
printf '\n== 3. No-auth request returns reason=missing-token ==\n'
curl -s -o /dev/null -D /tmp/h \
  -H 'Host: bookstore.local' -H 'x-device-posture: trusted' \
  http://localhost/api/anything
grep -i 'x-zta-decision-reason' /tmp/h
# Expected: x-zta-decision-reason: missing-token

# 4. The dashboard's deny-reason vocabulary now contains all three categories.
printf '\n== 4. Recent OPA log reasons cover the new vocabulary ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=5m \
  | jq -r 'select(.decision_id) | .result.headers["x-zta-decision-reason"]' \
  | sort -u
# Expected (subset): missing-token, no-matching-allow, device-tampered, ok
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/06-verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/06-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/06-zta.authz.rego \
        files/zta-homelab/labs/07-telemetry-loop/06-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 step 06 — refined Rego (split no-matching-allow) + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Break-it script

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/07-break-it.sh`

- [ ] **Step 1: Create `07-break-it.sh`** (from index.html line 6831; in-script repair)

```bash
#!/usr/bin/env bash
# Break-it exercise (Lab 7): disable OPA's decision-log console sink. The
# dashboard's deny-reasons panel goes silent within ~5 minutes — policy
# decisions are still enforced but no longer auditable, which is a SOX 404
# style gap (source 8.5).
#
# Run manually: bash 07-break-it.sh
# A repair stanza follows; comment it out if you want to leave the gap
# in place so the dashboard demonstration sticks.
set -euo pipefail

echo "Disabling OPA decision_logs.console..."
kubectl --context docker-desktop -n zta-policy patch configmap opa-config --type merge -p '
data:
  config.yaml: |
    services:
      pa: { url: http://opa-bundle-server.zta-policy.svc.cluster.local }
    bundles:
      zta: { resource: "bundles/zta.tar.gz", service: pa,
             polling: { min_delay_seconds: 5, max_delay_seconds: 10 },
             signing: { keyid: zta-bundle-key } }
    decision_logs: { console: false }
'
kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa
kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s
echo
echo "Decision logs disabled. Wait ~5 min and observe the dashboard's deny-reasons"
echo "panel emptying out. Repair below."
echo

# Repair: re-run Lab 6 step 03 to restore opa-config (the orchestrator regenerates
# the file from the template, then applies it).
read -r -p "Press Enter to repair (re-run Lab 6 step 03)... " _
( cd "$(dirname "${BASH_SOURCE[0]}")/../06-strict-enforcement" && \
  pub=$(cat keys/bundle-signer.pub) && \
  indent=$(grep '__BUNDLE_SIGNER_PUB__' 03-opa-config.yaml.tmpl | sed 's/__BUNDLE_SIGNER_PUB__.*//') && \
  pub_indented=$(sed "s/^/$indent/" keys/bundle-signer.pub) && \
  awk -v key="$pub_indented" '$0 ~ /__BUNDLE_SIGNER_PUB__/ { print key; next } { print }' \
    03-opa-config.yaml.tmpl > 03-opa-config.yaml && \
  kubectl --context docker-desktop apply --server-side --field-manager=zta-lab07 -f 03-opa-config.yaml && \
  kubectl --context docker-desktop -n zta-policy rollout restart deploy/opa && \
  kubectl --context docker-desktop -n zta-policy rollout status  deploy/opa --timeout=120s )
echo "Repaired. Decision-log console sink restored."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/07-break-it.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/07-break-it.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/07-break-it.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 break-it script (manual — disable decision-log console)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Orchestrator `00-telemetry-loop-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh`

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 7 — Telemetry Loop (NIST SP 800-207 Tenet 7) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent; ConfigMap rebuild from disk
# is idempotent.
#
# Prerequisite (cluster): bootstrap + Labs 1-6 already applied.
# Bootstrap is assumed to use kube-prometheus-stack release name 'kube-prom'.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab07)

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
step_01_servicemonitor() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 01-opa-servicemonitor.yaml
    echo
    echo "--- 01-verify.sh ---"
    bash 01-verify.sh
}

step_02_grafana_agent() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-grafana-agent.yaml
    kubectl --context "$KCTX" -n zta-observability rollout status ds/grafana-agent --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_istio_tracing() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 03-istio-tracing.yaml
    kubectl --context "$KCTX" -n istio-system rollout restart deploy/istiod
    kubectl --context "$KCTX" -n istio-system rollout status  deploy/istiod --timeout=120s
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_dashboard() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-dashboard.yaml
    echo "Waiting 15 s for the Grafana sidecar to pick up the new ConfigMap..."
    sleep 15
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_load_mix() {
    bash 05-load-mix.sh
    echo
    echo "--- 05-verify.sh ---"
    bash 05-verify.sh
}

step_06_refine_policy() {
    # Rebuild Lab 6's pa-policies ConfigMap from the refined Rego (this lab),
    # NOT from Lab 4's source. Then bounce the PA so it republishes the bundle.
    kubectl --context "$KCTX" -n zta-policy create configmap pa-policies \
        --from-file=zta.authz.rego=06-zta.authz.rego --dry-run=client -o yaml \
        | kubectl --context "$KCTX" apply "${SSA[@]}" -f -
    kubectl --context "$KCTX" -n zta-policy rollout restart deploy/pa
    kubectl --context "$KCTX" -n zta-policy rollout status  deploy/pa --timeout=180s
    echo "Waiting 15 s for OPA to fetch and verify the new bundle..."
    sleep 15
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-servicemonitor"  step_01_servicemonitor
run_step "02-grafana-agent"   step_02_grafana_agent
run_step "03-istio-tracing"   step_03_istio_tracing
run_step "04-dashboard"       step_04_dashboard
run_step "05-load-mix"        step_05_load_mix
run_step "06-refine-policy"   step_06_refine_policy

echo
echo "Lab 7 install completed successfully."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/00-telemetry-loop-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/07-telemetry-loop/verify.sh`

- [ ] **Step 1: Create `verify.sh`**

```bash
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

check "OPA /metrics returns at least one opa_ counter" \
  bash -c "pod=\$(kubectl --context $CTX -n zta-policy get pod -l app=opa -o name | head -1) && \
           [ \"\$(kubectl --context $CTX -n zta-policy exec \"\$pod\" -- \
                  wget -qO- http://localhost:8282/metrics | grep -c '^opa_')\" -ge 1 ]"

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

check "OPA /status: bundle activated within last 10 minutes" \
  bash -c "out=\$(kubectl --context $CTX -n zta-policy exec deploy/opa -- \
                  wget -qO- http://localhost:8282/status 2>/dev/null) && \
           act=\$(echo \"\$out\" | jq -r '.bundles.zta.last_successful_activation') && \
           ts=\$(date -u -d \"\$act\" +%s 2>/dev/null) && \
           now=\$(date -u +%s) && \
           [ \$((now - ts)) -lt 600 ]"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 7 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/07-telemetry-loop/verify.sh
chmod +x files/zta-homelab/labs/07-telemetry-loop/verify.sh
```

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/07-telemetry-loop/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 7 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Final smoke-check (controller runs this)

- [ ] **Step 1: List all created files**

```bash
ls -la files/zta-homelab/labs/07-telemetry-loop/
```
Expected: 14 files:
```
00-telemetry-loop-install.sh
01-opa-servicemonitor.yaml
01-verify.sh
02-grafana-agent.yaml
02-verify.sh
03-istio-tracing.yaml
03-verify.sh
04-dashboard.yaml
04-verify.sh
05-load-mix.sh
05-verify.sh
06-verify.sh
06-zta.authz.rego
07-break-it.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/07-telemetry-loop/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: all `OK`.

- [ ] **Step 3: YAML structural check**

```bash
for f in files/zta-homelab/labs/07-telemetry-loop/*.yaml; do
  yq eval '.' "$f" >/dev/null && echo "OK $f" || echo "BAD $f"
done
```
Expected: 4 `OK` lines.

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```

---

## Out of scope

- Master `install.sh` covering all 7 labs — separate session.
- Bootstrap and Labs 1–6.

## Dependencies (assumed present before running install)

- Bootstrap completed including kube-prometheus-stack (release `kube-prom`), Loki, Tempo, Grafana in `zta-observability`.
- Labs 1–6 completed.
- `kubectl`, `jq`, `yq`, `curl`, `awk`, `sed` on PATH.

## Self-review

**Spec coverage:**
- 14 files in spec → 14 files across Tasks 1–9. ✓
- Refined Rego shipped as a complete file → Task 6 step 1. ✓
- ConfigMap rebuild from refined Rego → orchestrator step_06. ✓
- Port-forward cleanup traps → present in 01/02/03/04/05 verifies and umbrella. ✓
- OPA `/status` via kubectl exec in umbrella + step 06 verify. ✓
- istio configmap caveat comment in YAML. ✓
- Acceptance criteria 1–9 covered by umbrella checks. ✓

**Placeholder scan:** No "TBD".

**Type/identifier consistency:**
- `KCTX`, `SSA`, `SCRIPT_DIR`, `BOOKSTORE_CLIENT_SECRET`, `TOKEN`, `PF_PID` — same names everywhere. ✓
- `kube-prom` release name used consistently across SM label + port-forwards. ✓
- File names consistent across tasks. ✓

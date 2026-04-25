# Lab 5 — Posture Monitoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Lab 5's snippets from `index.html` (lines 4961–5562) into runnable scripts and manifests following the established Lab 1–4 pattern.

**Architecture:** Files in `files/zta-homelab/labs/05-posture-monitoring/`. Bash and YAML mix: 4 YAMLs (CDM stack, EnvoyFilter+Deployment-patch, CronJob), 4 bash scripts (helm wiring, trigger, break-it, orchestrator), narrative per-step verifies, umbrella verify.

**Tech Stack:** bash 5+, kubectl, helm 3+, jq, curl, yq. Cluster: bootstrap-installed Falco DaemonSet, the `zta-runtime-security` namespace, plus everything from Labs 1–4.

**Spec:** `docs/superpowers/specs/2026-04-26-lab-5-posture-monitoring-design.md`

**Pattern reference:**
- `files/zta-homelab/labs/04-dynamic-policy/00-dynamic-policy-install.sh` — most recent orchestrator
- `files/zta-homelab/labs/04-dynamic-policy/verify.sh` — most recent umbrella

**Important pattern note:** Per-step verify scripts are *narrative* (printf headings, kubectl/helm verbatim, `# Expected:` comments — no `set -e`, no shebang, but `chmod +x`). The umbrella `verify.sh` is the strict pass/fail script.

---

## File Structure

All files in `files/zta-homelab/labs/05-posture-monitoring/`:

```
01-verify.sh                       # Step 1 (Falco status — observation only)
02-cdm.yaml                        # Step 2 manifest (SA, RBAC, ConfigMap, Deploy, Svc)
02-verify.sh                       # Step 2 narrative verify
03-falcosidekick.sh                # Step 3 helm upgrade
03-verify.sh                       # Step 3 narrative verify
04-posture-header.yaml             # Step 4 manifest (EnvoyFilter + Deployment patch)
04-verify.sh                       # Step 4 narrative verify
05-reconciler.yaml                 # Step 5 manifest (CronJob)
05-verify.sh                       # Step 5 narrative verify (mutates state — annotates pod)
06-trigger-detection.sh            # Step 6: fire shell-in-container
06-verify.sh                       # Step 6 narrative verify
07-break-it.sh                     # Manual break-it (NOT run by orchestrator)
00-posture-monitoring-install.sh   # Orchestrator
verify.sh                          # Umbrella pass/fail
```

---

## Pre-flight

- [ ] **Step P.1: Verify clean tree on main**

```bash
cd /home/i725081/projects/zta-financial-institution-c4-ai-homelab
git status
git rev-parse --abbrev-ref HEAD
```
Expected: clean, `main`.

- [ ] **Step P.2: Verify spec exists and lab dir is empty**

```bash
ls -l docs/superpowers/specs/2026-04-26-lab-5-posture-monitoring-design.md
ls files/zta-homelab/labs/05-posture-monitoring/
```
Expected: spec present; lab dir empty.

---

### Task 1: Step 01 — Falco verify (no apply)

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/01-verify.sh`

- [ ] **Step 1: Create `01-verify.sh`** (verbatim from index.html line 5107)

```bash
# 1. DaemonSet matches node count — every node has Falco; no monitoring gaps.
printf '\n== 1. Falco DaemonSet ready count matches node count ==\n'
NODES=$(kubectl --context docker-desktop get nodes --no-headers | wc -l)
READY=$(kubectl --context docker-desktop -n zta-runtime-security get ds falco \
          -o jsonpath='{.status.numberReady}')
echo "nodes=$NODES ready=$READY"
# Expected: nodes equals ready (e.g. nodes=1 ready=1 on Docker Desktop)

# 2. Driver reports as modern_ebpf and is loaded — not "skipped" / "fallback".
printf '\n== 2. modern_ebpf driver loaded ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=200 \
  | grep -E 'driver loaded|modern_ebpf' | head -2
# Expected: a 'modern_ebpf' line and a 'driver loaded' line

# 3. The default Falco rule set is loaded (Terminal shell in container is required by step 06).
printf '\n== 3. Default rules include Terminal shell in container ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=500 \
  | grep -c 'Terminal shell in container'
# Expected: >= 1   (rule will be referenced at engine startup or in tests)

# 4. Falco's metrics endpoint is up (T7 will scrape this in lab 7).
printf '\n== 4. Falco /healthz returns ok ==\n'
FALCO_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falco -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $FALCO_POD -- \
  wget -qO- http://localhost:8765/healthz
# Expected: ok   (or HTTP 200 body)
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/01-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/01-verify.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/01-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 01 — Falco status verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Step 02 — CDM stand-in

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/02-cdm.yaml`
- Create: `files/zta-homelab/labs/05-posture-monitoring/02-verify.sh`

- [ ] **Step 1: Create `02-cdm.yaml`** (verbatim from index.html line 5136)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: cdm, namespace: zta-runtime-security }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: cdm-patch-pods }
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","patch","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: cdm-patch-pods }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cdm-patch-pods }
subjects:
- { kind: ServiceAccount, name: cdm, namespace: zta-runtime-security }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: cdm-app, namespace: zta-runtime-security }
data:
  app.py: |
    # Minimal CDM stand-in: Falco webhook -> pod annotation
    import json, os, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from kubernetes import client, config
    config.load_incluster_config()
    v1 = client.CoreV1Api()

    class H(BaseHTTPRequestHandler):
      def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = json.loads(self.rfile.read(n) or b'{}')
        rule = body.get('rule','')
        out  = body.get('output_fields',{}) or {}
        ns   = out.get('k8s.ns.name')  or out.get('k8s_ns_name')
        pod  = out.get('k8s.pod.name') or out.get('k8s_pod_name')
        if ns and pod:
          posture = 'tampered' if 'Terminal shell' in rule or 'shell' in rule.lower() else 'suspect'
          patch = {'metadata':{'annotations':{'zta.posture': posture,
                                               'zta.posture.rule': rule,
                                               'zta.posture.at':  body.get('time','')}}}
          v1.patch_namespaced_pod(pod, ns, patch)
          print(f'PATCHED ns={ns} pod={pod} posture={posture} rule={rule}', flush=True)
        self.send_response(204); self.end_headers()
    HTTPServer(('0.0.0.0', 8080), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: cdm, namespace: zta-runtime-security, labels: { zta.resource: "true", zta.data-class: "internal", zta.owner: "soc" } }
spec:
  replicas: 1
  selector: { matchLabels: { app: cdm } }
  template:
    metadata: { labels: { app: cdm, zta.resource: "true", zta.data-class: "internal", zta.owner: "soc" } }
    spec:
      serviceAccountName: cdm
      containers:
      - name: app
        image: python:3.12-alpine
        command: ["sh","-c","pip install --quiet kubernetes==30.1.0 && python /app/app.py"]
        volumeMounts: [{ name: code, mountPath: /app }]
      volumes: [{ name: code, configMap: { name: cdm-app } }]
---
apiVersion: v1
kind: Service
metadata: { name: cdm, namespace: zta-runtime-security }
spec:
  selector: { app: cdm }
  ports: [{ name: http, port: 80, targetPort: 8080 }]
```

- [ ] **Step 2: Create `02-verify.sh`** (verbatim from index.html line 5221)

```bash
# 1. CDM Deployment ready, Service reachable on port 80.
printf '\n== 1. CDM Deployment 1/1 and Service exposes 80/8080 ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy cdm \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

kubectl --context docker-desktop -n zta-runtime-security get svc cdm \
  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}{"\n"}'
# Expected: 80/8080

# 2. RBAC is exactly the minimum needed (pods get/list/patch/watch — no more).
printf '\n== 2. ClusterRole verbs == [get,list,patch,watch]; can-i patch yes; can-i delete no ==\n'
kubectl --context docker-desktop get clusterrole cdm-patch-pods \
  -o jsonpath='{.rules[0].verbs}{"\n"}'
# Expected: ["get","list","patch","watch"]

kubectl --context docker-desktop auth can-i patch pods \
  --as=system:serviceaccount:zta-runtime-security:cdm -A
# Expected: yes

kubectl --context docker-desktop auth can-i delete pods \
  --as=system:serviceaccount:zta-runtime-security:cdm -A
# Expected: no   (CDM must NOT be able to delete — over-permissioning would break T5)

# 3. The CDM listens — POST a synthetic Falco event and confirm 204.
printf '\n== 3. CDM responds 204 to a synthetic Falco event ==\n'
CDM_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app=cdm -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $CDM_POD -- \
  wget -qO- --post-data='{"rule":"smoke","output_fields":{}}' \
  --header='Content-Type: application/json' \
  --server-response http://localhost:8080/ 2>&1 | grep -E 'HTTP/1\.[01] 204'
# Expected: a 'HTTP/1.x 204' line
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/02-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/02-verify.sh
yq eval '.' files/zta-homelab/labs/05-posture-monitoring/02-cdm.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/02-cdm.yaml \
        files/zta-homelab/labs/05-posture-monitoring/02-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 02 — CDM stand-in (SA/RBAC/ConfigMap/Deploy/Svc)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Step 03 — Falcosidekick wiring

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/03-falcosidekick.sh`
- Create: `files/zta-homelab/labs/05-posture-monitoring/03-verify.sh`

- [ ] **Step 1: Create `03-falcosidekick.sh`** (verbatim from index.html line 5257; wrapped as a runnable script)

```bash
#!/usr/bin/env bash
# Wire Falcosidekick to forward events to the CDM webhook.
# Idempotent: helm upgrade --install creates or updates the release.
set -euo pipefail

helm --kube-context docker-desktop upgrade --install falco falcosecurity/falco \
  --namespace zta-runtime-security --version 4.8.1 \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  --set falcosidekick.config.webhook.address=http://cdm.zta-runtime-security.svc.cluster.local/ \
  --set falcosidekick.config.webhook.minimumpriority=notice \
  --wait
```

- [ ] **Step 2: Create `03-verify.sh`** (verbatim from index.html line 5270)

```bash
# 1. Falcosidekick pod is up and reports the webhook address as the CDM service.
printf '\n== 1. falco-falcosidekick is 1/1 and WEBHOOK_ADDRESS points to CDM ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | jq -r '.[] | select(.name=="WEBHOOK_ADDRESS") | .value'
# Expected: http://cdm.zta-runtime-security.svc.cluster.local/

# 2. minimumpriority is 'notice' (not 'critical') — captures Terminal-shell.
printf '\n== 2. WEBHOOK_MINIMUMPRIORITY == notice ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy falco-falcosidekick \
  -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | jq -r '.[] | select(.name=="WEBHOOK_MINIMUMPRIORITY") | .value'
# Expected: notice

# 3. End-to-end: synthesise a Falco POST through Falcosidekick and confirm
#    the CDM logs the dispatch.
printf '\n== 3. Synthetic event via sidekick reaches CDM ==\n'
SK_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falcosidekick -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $SK_POD -- \
  wget -qO- --post-data='{"priority":"Notice","rule":"smoke","output_fields":{"k8s.ns.name":"bookstore-api","k8s.pod.name":"smoke"}}' \
  --header='Content-Type: application/json' http://localhost:2801/ >/dev/null
sleep 2
kubectl --context docker-desktop -n zta-runtime-security logs deploy/cdm --tail=20 | grep -c 'PATCHED\|smoke'
# Expected: >= 1
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/03-falcosidekick.sh
bash -n files/zta-homelab/labs/05-posture-monitoring/03-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/03-falcosidekick.sh \
        files/zta-homelab/labs/05-posture-monitoring/03-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/03-falcosidekick.sh \
        files/zta-homelab/labs/05-posture-monitoring/03-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 03 — Falcosidekick wiring (helm upgrade)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Step 04 — posture header projection

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/04-posture-header.yaml`
- Create: `files/zta-homelab/labs/05-posture-monitoring/04-verify.sh`

- [ ] **Step 1: Create `04-posture-header.yaml`** (verbatim from index.html line 5302)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata: { name: project-posture-header, namespace: bookstore-api }
spec:
  workloadSelector: { labels: { app: api } }
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      listener:
        filterChain: { filter: { name: "envoy.filters.network.http_connection_manager" } }
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.lua
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
          inlineCode: |
            function envoy_on_request(request_handle)
              local p = os.getenv("ZTA_POD_POSTURE") or "trusted"
              if request_handle:headers():get("x-device-posture") == nil then
                request_handle:headers():add("x-device-posture", p)
              end
            end
---
# Mount the pod annotation as an env var via the downward API.
# Requires a small patch to the api Deployment:
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: bookstore-api }
spec:
  template:
    spec:
      containers:
      - name: httpbin
        env:
        - name: ZTA_POD_POSTURE
          valueFrom:
            fieldRef: { fieldPath: metadata.annotations['zta.posture'] }
```

- [ ] **Step 2: Create `04-verify.sh`** (verbatim from index.html line 5354)

```bash
# 1. EnvoyFilter exists in bookstore-api and inserts a Lua HTTP filter.
printf '\n== 1. EnvoyFilter project-posture-header inserts Lua HTTP filter ==\n'
kubectl --context docker-desktop -n bookstore-api get envoyfilter project-posture-header \
  -o jsonpath='{.spec.configPatches[0].patch.value.name}{"\n"}'
# Expected: envoy.filters.http.lua

# 2. The Lua source actually contains the x-device-posture insertion logic.
printf '\n== 2. Lua source contains x-device-posture ==\n'
kubectl --context docker-desktop -n bookstore-api get envoyfilter project-posture-header \
  -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.inlineCode}' \
  | grep -c 'x-device-posture'
# Expected: 1

# 3. The api Deployment exposes ZTA_POD_POSTURE via downward API.
printf "\n== 3. api Deployment exposes ZTA_POD_POSTURE from metadata.annotations['zta.posture'] ==\n"
kubectl --context docker-desktop -n bookstore-api get deploy api \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="httpbin")].env}' \
  | jq -r '.[] | select(.name=="ZTA_POD_POSTURE") | .valueFrom.fieldRef.fieldPath'
# Expected: metadata.annotations['zta.posture']

# 4. Live request from the frontend now carries the header even when the caller did not.
printf '\n== 4. frontend->api response carries X-Device-Posture (not "missing") ==\n'
FRONTEND=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1)
kubectl --context docker-desktop -n bookstore-frontend exec $FRONTEND -c nginx -- \
  wget -qO- 'http://api.bookstore-api.svc.cluster.local/headers' \
  | jq -r '.headers["X-Device-Posture"] // "missing"'
# Expected: a string ('trusted' if no annotation set yet, or whatever the
#           current pod annotation says) — must NOT be "missing"
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/04-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/04-verify.sh
yq eval '.' files/zta-homelab/labs/05-posture-monitoring/04-posture-header.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/04-posture-header.yaml \
        files/zta-homelab/labs/05-posture-monitoring/04-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 04 — posture header projection (Lua + downward API)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Step 05 — reconciler CronJob

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/05-reconciler.yaml`
- Create: `files/zta-homelab/labs/05-posture-monitoring/05-verify.sh`

- [ ] **Step 1: Create `05-reconciler.yaml`** (verbatim from index.html line 5387)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: posture-reconciler, namespace: zta-runtime-security }
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cdm
          restartPolicy: OnFailure
          containers:
          - name: reconcile
            image: bitnami/kubectl:1.30
            command:
            - sh
            - -c
            - |
              for p in $(kubectl get pods -A -l app=api \
                    -o jsonpath='{range .items[?(@.metadata.annotations.zta\.posture)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
                NS=${p%/*}; POD=${p#*/}
                ENV_NOW=$(kubectl get pod -n $NS $POD -o jsonpath='{.spec.containers[?(@.name=="httpbin")].env[?(@.name=="ZTA_POD_POSTURE")].value}' || true)
                ANN_NOW=$(kubectl get pod -n $NS $POD -o jsonpath='{.metadata.annotations.zta\.posture}')
                if [ "$ENV_NOW" != "$ANN_NOW" ]; then
                  echo "bouncing $NS/$POD: env=$ENV_NOW ann=$ANN_NOW"
                  kubectl delete pod -n $NS $POD --wait=false
                fi
              done
```

- [ ] **Step 2: Create `05-verify.sh`** (verbatim from index.html line 5427; mutates state — annotates pod)

```bash
# 1. CronJob exists with the every-minute schedule.
printf '\n== 1. posture-reconciler CronJob schedule == */1 * * * * ==\n'
kubectl --context docker-desktop -n zta-runtime-security get cronjob posture-reconciler \
  -o jsonpath='{.spec.schedule}{"\n"}'
# Expected: */1 * * * *

# 2. CronJob runs as the cdm ServiceAccount (RBAC-bound, not cluster-admin).
printf '\n== 2. CronJob runs as serviceAccount cdm ==\n'
kubectl --context docker-desktop -n zta-runtime-security get cronjob posture-reconciler \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}{"\n"}'
# Expected: cdm

# 3. End-to-end smoke: annotate the api pod & wait for reconcile to fire,
#    then confirm the env var on the new pod matches the annotation.
printf '\n== 3. End-to-end: annotate api pod and wait <=75s for bounce ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
kubectl --context docker-desktop -n bookstore-api annotate --overwrite pod/$POD zta.posture=suspect
# Wait up to ~75 s for the next CronJob tick + a fresh pod.
for i in $(seq 1 25); do
  NEW=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2)
  if [ "$NEW" != "$POD" ]; then
    sleep 5
    NEWANN=$(kubectl --context docker-desktop -n bookstore-api get pod $NEW -o jsonpath='{.metadata.annotations.zta\.posture}')
    NEWENV=$(kubectl --context docker-desktop -n bookstore-api get pod $NEW -o jsonpath='{.spec.containers[?(@.name=="httpbin")].env[?(@.name=="ZTA_POD_POSTURE")].value}')
    echo "ann=$NEWANN env=$NEWENV"
    break
  fi
  sleep 3
done
# Expected (after at most ~75 s): ann=suspect env=metadata.annotations['zta.posture']
#                                 (the env var spec is preserved; new pod resolves it.)
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/05-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/05-verify.sh
yq eval '.' files/zta-homelab/labs/05-posture-monitoring/05-reconciler.yaml >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/05-reconciler.yaml \
        files/zta-homelab/labs/05-posture-monitoring/05-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 05 — posture-reconciler CronJob

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Step 06 — trigger detection + verify

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/06-trigger-detection.sh`
- Create: `files/zta-homelab/labs/05-posture-monitoring/06-verify.sh`

- [ ] **Step 1: Create `06-trigger-detection.sh`** (from index.html line 5462; `kubectl exec -it` becomes `kubectl exec` for non-TTY orchestrator runs)

```bash
#!/usr/bin/env bash
# Trigger Falco's "Terminal shell in container" rule on the api pod.
# This causes a chain: Falco event -> sidekick -> CDM patch -> annotation
# 'tampered' -> reconciler bounces pod -> new pod with ZTA_POD_POSTURE=tampered.
set -euo pipefail

# Before:
echo "Annotation before trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo

# Fire the shell-in-container rule (no TTY — orchestrator runs unattended):
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c httpbin -- sh -c 'exit 0'

sleep 10

# Falco event visible:
echo "Falco recent log lines:"
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=50 \
  | grep -E 'Terminal shell in container' | head -2 || true

# CDM should have patched the annotation:
echo "Annotation after trigger:"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo
```

- [ ] **Step 2: Create `06-verify.sh`** (verbatim from index.html line 5489)

```bash
# 1. Falco emitted the rule with priority >= notice.
printf '\n== 1. Falco emitted Terminal shell in container with k8s ns/pod ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --since=2m \
  | jq -c 'select(.rule=="Terminal shell in container") | {priority, k8s_ns: .output_fields["k8s.ns.name"], k8s_pod: .output_fields["k8s.pod.name"]}' \
  | head -1
# Expected: a JSON line with priority=Notice (or Warning/Critical) and k8s_ns=bookstore-api

# 2. CDM logs show it received the event and patched.
printf '\n== 2. CDM logs PATCHED ns=bookstore-api ... posture=tampered ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs deploy/cdm --since=2m \
  | grep -E 'PATCHED.*bookstore-api.*posture=tampered' | head -1
# Expected: a line containing PATCHED ns=bookstore-api ... posture=tampered

# 3. Pod annotation is now 'tampered' AND it carries the rule that fired.
printf '\n== 3. Pod annotation: posture=tampered, rule contains Terminal shell, at non-empty ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1)
kubectl --context docker-desktop -n bookstore-api get $POD \
  -o jsonpath='{.metadata.annotations}' | jq '{posture: .["zta.posture"], rule: .["zta.posture.rule"], at: .["zta.posture.at"]}'
# Expected: posture=tampered, rule contains 'Terminal shell', at is non-empty

# 4. Posture flows to the wire: a fresh request now carries x-device-posture: tampered.
printf '\n== 4. frontend->api response shows X-Device-Posture: tampered ==\n'
FRONTEND=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1)
sleep 5
kubectl --context docker-desktop -n bookstore-frontend exec $FRONTEND -c nginx -- \
  wget -qO- 'http://api.bookstore-api.svc.cluster.local/headers' \
  | jq -r '.headers["X-Device-Posture"]'
# Expected: tampered
```

- [ ] **Step 3: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/06-trigger-detection.sh
bash -n files/zta-homelab/labs/05-posture-monitoring/06-verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/06-trigger-detection.sh \
        files/zta-homelab/labs/05-posture-monitoring/06-verify.sh
```

- [ ] **Step 4: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/06-trigger-detection.sh \
        files/zta-homelab/labs/05-posture-monitoring/06-verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 step 06 — trigger detection + verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Break-it script

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/07-break-it.sh`

- [ ] **Step 1: Create `07-break-it.sh`** (from index.html line 5546; framed as a manual one-shot)

```bash
#!/usr/bin/env bash
# Break-it exercise (Lab 5): disable the Falcosidekick webhook subscriber and
# repeat the shell-in-container event. The annotation no longer changes; the
# policy stays at trusted. CDM signal is silently lost — the case Tenet 5
# warns about.
#
# Run manually: bash 07-break-it.sh
# Repair (in-script at the end) re-applies the helm upgrade with the webhook URL.
set -euo pipefail

echo "Disabling sidekick webhook (set WEBHOOK_ADDRESS='')..."
kubectl --context docker-desktop -n zta-runtime-security set env \
  deploy/falco-falcosidekick WEBHOOK_ADDRESS=''

# Trigger the shell.
kubectl --context docker-desktop -n bookstore-api exec \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1) \
  -c httpbin -- sh -c 'exit 0'
sleep 10

echo "Annotation after trigger (should be UNCHANGED — signal lost):"
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.annotations.zta\.posture}'; echo
# Expected: unchanged (possibly empty or the last known value) — signal lost.

# Repair:
echo "Repair: re-running helm upgrade with the webhook URL restored..."
helm --kube-context docker-desktop upgrade falco falcosecurity/falco \
  -n zta-runtime-security --reuse-values \
  --set falcosidekick.config.webhook.address=http://cdm.zta-runtime-security.svc.cluster.local/
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/07-break-it.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/07-break-it.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/07-break-it.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 break-it script (manual exercise)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Orchestrator `00-posture-monitoring-install.sh`

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh`

- [ ] **Step 1: Create the orchestrator**

```bash
#!/usr/bin/env bash
# Lab 5 — Posture Monitoring (NIST SP 800-207 Tenet 5) installer.
# Applies each step's manifest in order, runs the matching verify script,
# and pauses between steps so the learner can read the output.
# Re-runnable: kubectl applies are idempotent, helm upgrade --install is idempotent.
#
# Prerequisite (host): helm 3+ on PATH; falcosecurity helm repo added.
# Prerequisite (cluster): bootstrap + Labs 1-4 already applied.
set -euo pipefail

KCTX="docker-desktop"
SSA=(--server-side --field-manager=zta-lab05)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pre-check helm prerequisites before doing anything.
command -v helm >/dev/null || { echo "ERROR: helm not on PATH"; exit 1; }
helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx falcosecurity || {
  echo "ERROR: helm repo 'falcosecurity' not added. Run:"
  echo "  helm repo add falcosecurity https://falcosecurity.github.io/charts"
  echo "  helm repo update"
  exit 1
}

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
step_01_falco() {
    bash 01-verify.sh
}

step_02_cdm() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 02-cdm.yaml
    kubectl --context "$KCTX" -n zta-runtime-security rollout status deploy/cdm --timeout=180s
    echo
    echo "--- 02-verify.sh ---"
    bash 02-verify.sh
}

step_03_sidekick() {
    bash 03-falcosidekick.sh
    echo
    echo "--- 03-verify.sh ---"
    bash 03-verify.sh
}

step_04_posture_header() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 04-posture-header.yaml
    kubectl --context "$KCTX" -n bookstore-api rollout status deploy/api --timeout=180s
    echo
    echo "--- 04-verify.sh ---"
    bash 04-verify.sh
}

step_05_reconciler() {
    kubectl --context "$KCTX" apply "${SSA[@]}" -f 05-reconciler.yaml
    echo
    echo "--- 05-verify.sh (this verify intentionally mutates pod state) ---"
    bash 05-verify.sh
}

step_06_trigger() {
    bash 06-trigger-detection.sh
    echo
    echo "Waiting 90 s for Falco event -> sidekick -> CDM -> reconciler bounce..."
    for i in $(seq 1 90); do
        printf '\rwaited %ds / 90s' "$i"
        sleep 1
    done
    echo
    echo
    echo "--- 06-verify.sh ---"
    bash 06-verify.sh
}

# ---------------------------------------------------------------------------
run_step "01-falco"           step_01_falco
run_step "02-cdm"             step_02_cdm
run_step "03-sidekick"        step_03_sidekick
run_step "04-posture-header"  step_04_posture_header
run_step "05-reconciler"      step_05_reconciler
run_step "06-trigger"         step_06_trigger

echo
echo "Lab 5 install completed successfully."
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh
```

- [ ] **Step 3: Commit**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/00-posture-monitoring-install.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 install orchestrator with per-step pauses

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Umbrella `verify.sh`

**Files:**
- Create: `files/zta-homelab/labs/05-posture-monitoring/verify.sh`

- [ ] **Step 1: Create `verify.sh`**

```bash
#!/usr/bin/env bash
# Lab 5 — Posture Monitoring (NIST SP 800-207 Tenet 5).
# Read-only verification: asserts each step's outcome without changing cluster state.
# Exits non-zero on the first failed assertion.
set -euo pipefail
CTX=${CTX:-docker-desktop}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
section "Step 01 — Falco running"

check "Falco DaemonSet exists in zta-runtime-security" \
  kubectl --context "$CTX" -n zta-runtime-security get ds falco

check "Falco DaemonSet ready count == node count" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get ds falco \
                  -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context $CTX get nodes --no-headers | wc -l | tr -d ' ')\" ]"

# ---------------------------------------------------------------------------
section "Step 02 — CDM stand-in"

check "cdm Deployment is 1/1 ready" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get deploy cdm \
                  -o jsonpath='{.status.readyReplicas}/{.status.replicas}')\" = '1/1' ]"

check "cdm Service exposes 80 -> 8080" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get svc cdm \
                  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}')\" = '80/8080' ]"

check "ClusterRole cdm-patch-pods has only get/list/patch/watch" \
  bash -c "[ \"\$(kubectl --context $CTX get clusterrole cdm-patch-pods \
                  -o jsonpath='{.rules[0].verbs}')\" = '[\"get\",\"list\",\"patch\",\"watch\"]' ]"

check "cdm SA can patch pods" \
  bash -c "[ \"\$(kubectl --context $CTX auth can-i patch pods \
                  --as=system:serviceaccount:zta-runtime-security:cdm -A 2>/dev/null)\" = 'yes' ]"

check "cdm SA cannot delete pods" \
  bash -c "[ \"\$(kubectl --context $CTX auth can-i delete pods \
                  --as=system:serviceaccount:zta-runtime-security:cdm -A 2>/dev/null)\" = 'no' ]"

# ---------------------------------------------------------------------------
section "Step 03 — Falcosidekick wiring"

check "falco-falcosidekick is 1/1 ready" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get deploy falco-falcosidekick \
                  -o jsonpath='{.status.readyReplicas}/{.status.replicas}')\" = '1/1' ]"

check "WEBHOOK_ADDRESS points to cdm service" \
  bash -c "kubectl --context $CTX -n zta-runtime-security get deploy falco-falcosidekick \
            -o jsonpath='{.spec.template.spec.containers[0].env}' \
            | jq -r '.[] | select(.name==\"WEBHOOK_ADDRESS\") | .value' \
            | grep -qx 'http://cdm.zta-runtime-security.svc.cluster.local/'"

check "WEBHOOK_MINIMUMPRIORITY == notice" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get deploy falco-falcosidekick \
                  -o jsonpath='{.spec.template.spec.containers[0].env}' \
                  | jq -r '.[] | select(.name==\"WEBHOOK_MINIMUMPRIORITY\") | .value')\" = 'notice' ]"

# ---------------------------------------------------------------------------
section "Step 04 — posture header projection"

check "EnvoyFilter project-posture-header exists in bookstore-api" \
  kubectl --context "$CTX" -n bookstore-api get envoyfilter project-posture-header

check "EnvoyFilter inserts envoy.filters.http.lua" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get envoyfilter project-posture-header \
                  -o jsonpath='{.spec.configPatches[0].patch.value.name}')\" = 'envoy.filters.http.lua' ]"

check "Lua source contains x-device-posture" \
  bash -c "kubectl --context $CTX -n bookstore-api get envoyfilter project-posture-header \
            -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.inlineCode}' \
            | grep -q 'x-device-posture'"

check "api Deployment exposes ZTA_POD_POSTURE via downward API" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get deploy api \
                  -o jsonpath='{.spec.template.spec.containers[?(@.name==\"httpbin\")].env}' \
                  | jq -r '.[] | select(.name==\"ZTA_POD_POSTURE\") | .valueFrom.fieldRef.fieldPath')\" = \"metadata.annotations['zta.posture']\" ]"

# ---------------------------------------------------------------------------
section "Step 05 — reconciler CronJob"

check "posture-reconciler CronJob exists with schedule */1 * * * *" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get cronjob posture-reconciler \
                  -o jsonpath='{.spec.schedule}')\" = '*/1 * * * *' ]"

check "posture-reconciler runs as serviceAccount cdm" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get cronjob posture-reconciler \
                  -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}')\" = 'cdm' ]"

# ---------------------------------------------------------------------------
section "Step 06 — detection -> annotation -> wire"

check "api pod annotation zta.posture == tampered" \
  bash -c "[ \"\$(kubectl --context $CTX -n bookstore-api get pod -l app=api \
                  -o jsonpath='{.items[0].metadata.annotations.zta\\.posture}')\" = 'tampered' ]"

check "frontend->api wget shows X-Device-Posture: tampered" \
  bash -c "fp=\$(kubectl --context $CTX -n bookstore-frontend get pod -l app=frontend -o name | head -1) && \
           [ \"\$(kubectl --context $CTX -n bookstore-frontend exec \"\$fp\" -c nginx -- \
                  wget -qO- 'http://api.bookstore-api.svc.cluster.local/headers' \
                  | jq -r '.headers[\"X-Device-Posture\"]')\" = 'tampered' ]"

# ---------------------------------------------------------------------------
section "Lab-5 validation — Lab 4 policy denies on tampered posture"

# Acquire a token from Lab 3's .env, hit the api, assert 403.
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"
TOKEN=""
if [ -s "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

check "frontend->api request returns HTTP 403 (tampered posture denied)" \
  bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' \
                  -H 'Host: bookstore.local' -H 'Authorization: Bearer $TOKEN' \
                  http://localhost/api/headers)\" = '403' ]"

check "OPA decision log shows reason device-tampered (recent)" \
  bash -c "kubectl --context $CTX -n zta-policy logs deploy/opa --tail=20 \
            | jq -r 'select(.result.headers[\"x-zta-decision-reason\"]==\"device-tampered\") | .result.headers[\"x-zta-decision-reason\"]' \
            | grep -qx 'device-tampered'"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 5 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
```

- [ ] **Step 2: Smoke-check + chmod**

```bash
bash -n files/zta-homelab/labs/05-posture-monitoring/verify.sh
chmod +x files/zta-homelab/labs/05-posture-monitoring/verify.sh
```

- [ ] **Step 3: Commit and push**

```bash
git add files/zta-homelab/labs/05-posture-monitoring/verify.sh
git commit -m "$(cat <<'EOF'
Add Lab 5 umbrella verify.sh (strict pass/fail)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Final smoke-check (controller runs this)

- [ ] **Step 1: List all 14 created files**

```bash
ls -la files/zta-homelab/labs/05-posture-monitoring/
```
Expected: 14 files:
```
00-posture-monitoring-install.sh
01-verify.sh
02-cdm.yaml
02-verify.sh
03-falcosidekick.sh
03-verify.sh
04-posture-header.yaml
04-verify.sh
05-reconciler.yaml
05-verify.sh
06-trigger-detection.sh
06-verify.sh
07-break-it.sh
verify.sh
```

- [ ] **Step 2: Bash-syntax-check every shell file**

```bash
for f in files/zta-homelab/labs/05-posture-monitoring/*.sh; do
  bash -n "$f" && echo "OK $f" || echo "BAD $f"
done
```
Expected: 11 lines, all `OK`.

- [ ] **Step 3: YAML structural check**

```bash
for f in files/zta-homelab/labs/05-posture-monitoring/*.yaml; do
  yq eval '.' "$f" >/dev/null && echo "OK $f" || echo "BAD $f"
done
```
Expected: 3 `OK` lines.

- [ ] **Step 4: Confirm git tree is clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`.

---

## Out of scope

- Master `install.sh` covering all 7 labs.
- Labs 6–7.
- Bootstrap and Labs 1–4.

## Dependencies (assumed present before running install)

- Bootstrap completed (Falco DaemonSet in `zta-runtime-security`, Istio, Keycloak, OPA).
- Labs 1–4 completed (Lab 4's policy in particular — its `device-tampered` reason is what the umbrella's "validation" section asserts).
- `kubectl`, `helm` 3+, `jq`, `curl`, `yq` on PATH.
- `helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update`.
- Cluster context `docker-desktop`.
- Host can reach `http://localhost/...` with `Host: keycloak.local` and `Host: bookstore.local`.

## Self-review

**Spec coverage:**
- 14 files in spec → 14 files across Tasks 1–9. ✓
- Helm prereq pre-check in orchestrator → Task 8. ✓
- 90 s wait after step 06 trigger → Task 8. ✓
- TTY-less `kubectl exec` (no `-it`) in `06-trigger-detection.sh` → Task 6. ✓
- Lab 3 `.env` path via SCRIPT_DIR in umbrella → Task 9. ✓
- Acceptance criteria (1–10) covered by umbrella checks. ✓

**Placeholder scan:** No "TBD" / "TODO".

**Type/identifier consistency:**
- `KCTX`, `SSA`, `SCRIPT_DIR`, `BOOKSTORE_CLIENT_SECRET`, `TOKEN` — same names everywhere. ✓
- File names consistent across tasks. ✓
- Container name `httpbin` referenced in step 4 YAML, step 4 verify, step 5 verify, step 5 reconciler — all consistent.

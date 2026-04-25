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

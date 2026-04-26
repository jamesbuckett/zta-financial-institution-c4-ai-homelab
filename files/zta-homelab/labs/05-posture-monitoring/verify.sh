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

# Helm chart's default replicas is 2 (and we don't override). Use the same
# readyReplicas==replicas test as 03-verify.sh does. WEBHOOK_* settings are
# loaded via `envFrom: secretRef: falco-falcosidekick`, so read the secret.
check "falco-falcosidekick rollout is fully ready (readyReplicas==replicas)" \
  bash -c "ready=\$(kubectl --context $CTX -n zta-runtime-security get deploy falco-falcosidekick -o jsonpath='{.status.readyReplicas}') && \
           total=\$(kubectl --context $CTX -n zta-runtime-security get deploy falco-falcosidekick -o jsonpath='{.status.replicas}') && \
           [ -n \"\$ready\" ] && [ \"\$ready\" = \"\$total\" ]"

check "WEBHOOK_ADDRESS points to cdm service" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get secret falco-falcosidekick \
                  -o jsonpath='{.data.WEBHOOK_ADDRESS}' | base64 -d)\" = 'http://cdm.zta-runtime-security.svc.cluster.local/' ]"

check "WEBHOOK_MINIMUMPRIORITY == notice" \
  bash -c "[ \"\$(kubectl --context $CTX -n zta-runtime-security get secret falco-falcosidekick \
                  -o jsonpath='{.data.WEBHOOK_MINIMUMPRIORITY}' | base64 -d)\" = 'notice' ]"

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

# The api pod's posture annotation transitions back to 'trusted' once Lab 6's
# close-loop runs (operator-remediation pattern). After install completes the
# api pod is therefore in trusted state — checking for "currently tampered"
# would only pass during the brief window between Lab 5's trigger and Lab 6's
# close-loop. Instead, prove the CDM chain actually ran by checking it logged
# a PATCHED event for the api Deployment in the recent CDM log.
check "CDM has handled at least one Falco event for the bookstore-api workload" \
  bash -c "kubectl --context $CTX -n zta-runtime-security logs deploy/cdm --tail=200 \
            | grep -qE '^(PATCHED|NOOP) ns=bookstore-api .*posture='"

# When the pod is in posture=tampered, Lab 4's OPA denies the request before
# upstream can echo the request-headers body. So we can't read X-Device-Posture
# out of an httpbin response (no body on a 403). Instead, check that OPA's
# decision log saw x-device-posture=tampered in the request input — that
# proves the Lua filter injected the header before ext_authz ran.
# Use `logs -l app=opa` (not `logs deploy/opa`) because OPA runs 2 replicas
# and `kubectl logs deploy/...` reads only the first pod — the decision we
# need may have landed on the other one via Service load-balancing.
check "OPA decision log shows x-device-posture=tampered injected by Lua filter" \
  bash -c "kubectl --context $CTX -n zta-policy logs -l app=opa --tail=200 \
            | jq -r 'select(.path == \"zta/authz/result\") | .input.attributes.request.http.headers[\"x-device-posture\"] // empty' \
            | grep -qx tampered"

# ---------------------------------------------------------------------------
section "Lab-5 validation — Lab 4 policy denies on tampered posture"

# Acquire a token from Lab 3's .env, hit the api, assert 403.
# Refresh .env from Keycloak first (see refresh-env.sh for the why).
ENV_FILE="$SCRIPT_DIR/../03-per-session/.env"
KCTX=$CTX bash "$SCRIPT_DIR/../03-per-session/refresh-env.sh" || true
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

# Send x-device-posture: tampered explicitly so the check exercises the
# policy's tampered-deny branch regardless of what the api pod's current
# annotation/Lua-injected posture happens to be.
check "frontend->api request with x-device-posture=tampered returns HTTP 403" \
  bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' \
                  -H 'Host: bookstore.local' -H 'Authorization: Bearer $TOKEN' \
                  -H 'x-device-posture: tampered' \
                  http://localhost/api/headers)\" = '403' ]"

# Same multi-pod caveat as the previous OPA-log check. Also bump --tail from
# 20 to 200: kubelet's /health probes emit ~2 lines every ~10s, so --tail=20
# only covers the last ~100s on a single pod and merging two pods halves
# that window — easily losing the decision the curl above just made.
check "OPA decision log shows reason device-tampered (recent)" \
  bash -c "kubectl --context $CTX -n zta-policy logs -l app=opa --tail=200 \
            | jq -r 'select(.result?.headers?[\"x-zta-decision-reason\"]==\"device-tampered\") | .result.headers[\"x-zta-decision-reason\"]' \
            | grep -qx 'device-tampered'"

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'Lab 5 verify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

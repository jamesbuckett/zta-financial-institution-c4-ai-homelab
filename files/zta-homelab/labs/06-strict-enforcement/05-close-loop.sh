#!/usr/bin/env bash
# Close the loop: posture=tampered -> 403 deny, operator clears annotation,
# new pod resolves to trusted, second request returns 200. Re-runnable: we
# force the api pod template to tampered up front so round 1 actually denies
# even on a cluster where Lab 5's CDM already cleared back to trusted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Refresh .env from Keycloak first (see refresh-env.sh for the why).
bash "$SCRIPT_DIR/../03-per-session/refresh-env.sh" || true
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../03-per-session/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

# Helper: poll the api endpoint via the ingress until it stops returning the
# transient 503 (stale Envoy endpoints during rollout) and settles on the
# expected code. `kubectl rollout status` reports rollout-complete based on
# pod readiness, not on Envoy's xDS converging — the first request after a
# bounce can hit "no healthy upstream" / 503 even though kubectl says we're
# done.
wait_for_code() {
  local want="$1" code i
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
      http://localhost/api/headers)
    if [ "$code" = "$want" ]; then
      echo "$code"
      return 0
    fi
    sleep 1
  done
  echo "$code"   # last code seen, for diagnostics
  return 1
}

# Force a tampered state up front. The Lab 5 chain (Falco -> sidekick ->
# CDM) is what would normally drive this; on re-runs the cluster might
# already be back to trusted, in which case round 1 below would falsely
# return 200 and the verify wouldn't see any recent deny in OPA's log.
kubectl --context docker-desktop -n bookstore-api patch deploy api --type=merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"zta.posture":"tampered"}}}}}' >/dev/null
kubectl --context docker-desktop -n bookstore-api rollout status deploy/api --timeout=180s

# Round 1 — denied (poll past the rollout-driven 503 window):
echo "round1=$(wait_for_code 403)"
# Expected: round1=403

# Operator remediates. The Lab 5 CDM patches BOTH the live pod and the owning
# Deployment's pod template, so the tampered annotation lives in the template
# too — clearing only the live pod's annotation gets immediately reverted on
# bounce because the new pod inherits 'tampered' from the template. Patch
# the template back to 'trusted' so the rollout produces a clean pod.
kubectl --context docker-desktop -n bookstore-api patch deploy api --type=merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"zta.posture":"trusted"}}}}}'
# Patching the Deployment template triggers a rollout automatically, so we
# don't also need to delete the running pod by hand.
kubectl --context docker-desktop -n bookstore-api rollout status deploy/api --timeout=180s

# Round 2 — allowed (same poll, different expected code):
echo "round2=$(wait_for_code 200)"
# Expected: round2=200

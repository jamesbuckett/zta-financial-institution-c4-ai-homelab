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

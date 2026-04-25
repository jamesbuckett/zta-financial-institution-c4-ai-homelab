# 1. At least 6 decision lines exist in the OPA log — one per request.
printf '\n== 1. OPA decision log has >= 6 lines ==\n'
DECISIONS=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -c 'select(.decision_id != null)' 2>/dev/null | wc -l)
echo "decisions=$DECISIONS"
# Expected: decisions >= 6

# 2. Each decision_id is unique (it is a per-request audit handle, not a label).
printf '\n== 2. Last 6 decision_ids are all unique ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -r 'select(.decision_id != null) | .decision_id' | tail -6 | sort -u | wc -l
# Expected: 6

# 3. The reasons populate the four expected categories.
printf '\n== 3. Reasons cover ok / device-tampered / no-matching-allow ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=200 \
  | jq -r 'select(.result.headers["x-zta-decision-reason"]) | .result.headers["x-zta-decision-reason"]' \
  | sort -u
# Expected (subset): ok, device-tampered, no-matching-allow

# 4. Every decision carries the input shape Envoy actually sent — proves
#    the audit row is complete enough to reconstruct the call.
printf '\n== 4. Each decision has method, posture, principal in input ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --tail=20 \
  | jq -c 'select(.decision_id) | {has_method: (.input.attributes.request.http.method != null), has_posture: (.input.attributes.request.http.headers["x-device-posture"] != null), has_principal: (.input.attributes.source.principal != null)}' \
  | sort -u
# Expected: {"has_method":true,"has_posture":true,"has_principal":true}

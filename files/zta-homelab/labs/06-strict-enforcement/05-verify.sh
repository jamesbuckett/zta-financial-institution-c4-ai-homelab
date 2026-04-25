# 1. Two decisions logged in the last 60 s — one deny, one allow.
printf '\n== 1. >=1 deny and >=1 allow in last 60s ==\n'
DENY=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -c 'select(.decision_id and .result.allowed==false)' | wc -l)
ALLOW=$(kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -c 'select(.decision_id and .result.allowed==true)'  | wc -l)
echo "deny=$DENY allow=$ALLOW"
# Expected: deny >= 1  allow >= 1

# 2. Reasons are exactly 'device-tampered' (round 1) and 'ok' (round 2).
printf '\n== 2. Last two reasons are device-tampered and ok ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -r 'select(.decision_id) | .result.headers["x-zta-decision-reason"]' \
  | tail -2 | sort -u
# Expected:
#   device-tampered
#   ok

# 3. The two decision_ids differ — same Alice, different decisions, distinct audit rows.
printf '\n== 3. Last two decision_ids are distinct ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/opa --since=60s \
  | jq -r 'select(.decision_id) | .decision_id' | tail -2 | sort -u | wc -l
# Expected: 2

# 4. The pod that served round 2 is a DIFFERENT pod from round 1
#    (operator deletion forced a fresh ZTA_POD_POSTURE env var).
printf '\n== 4. api pod creationTimestamp is recent ==\n'
kubectl --context docker-desktop -n bookstore-api get pod -l app=api \
  -o jsonpath='{.items[0].metadata.creationTimestamp}{"\n"}'
# Expected: a recent timestamp (within a couple of minutes), proving the pod
#           is fresh — its env var resolved 'trusted' from the new annotation.

# 1. Each workload carries the three required labels (T1).
printf '\n== 1. Each bookstore workload carries the three required labels ==\n'
for tuple in 'bookstore-frontend deployment frontend' \
             'bookstore-api      deployment api' \
             'bookstore-data     statefulset db'; do
  read -r ns kind name <<<"$tuple"
  kubectl --context docker-desktop -n "$ns" get "$kind" "$name" \
    -o jsonpath='{.metadata.labels.zta\.resource}{" "}{.metadata.labels.zta\.data-class}{" "}{.metadata.labels.zta\.owner}{"\n"}'
done
# Expected:
#   true public       retail-web
#   true confidential retail-api
#   true restricted   retail-data

# 2. Field manager is zta-lab01 — proves these labels were set by THIS step,
#    not silently re-asserted by an earlier client-side apply.
#    --show-managed-fields is required because kubectl strips that array by default.
printf '\n== 2. Field manager zta-lab01 owns labels on api Deployment ==\n'
kubectl --context docker-desktop -n bookstore-api get deploy api \
  --show-managed-fields -o json \
  | jq -r '[.metadata.managedFields[]? | select(.manager=="zta-lab01") | .manager] | unique[]'
# Expected: zta-lab01

# 3. Per-framework regulatory flags landed.
printf '\n== 3. Per-framework regulatory flags on db StatefulSet ==\n'
kubectl --context docker-desktop -n bookstore-data get statefulset db \
  -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key|startswith("zta.regulatory.")))'
# Expected: {"zta.regulatory.gdpr":"true","zta.regulatory.pci":"true","zta.regulatory.sox":"true"}


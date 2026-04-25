# 1. Empty-spec deny exists in the two protected namespaces.
printf '\n== 1. Empty-spec default-deny in bookstore-api and bookstore-data ==\n'
for ns in bookstore-api bookstore-data; do
  kubectl --context docker-desktop -n "$ns" get authorizationpolicy default-deny \
    -o jsonpath='{.metadata.namespace}/{.metadata.name} spec={.spec}{"\n"}'
done
# Expected:
#   bookstore-api/default-deny  spec={}
#   bookstore-data/default-deny spec={}

# 2. Allow-rule exists for ingress -> frontend, and ingress+frontend -> api.
printf '\n== 2. Allow rules — ingress -> frontend ==\n'
kubectl --context docker-desktop -n bookstore-frontend get authorizationpolicy allow-ingress-to-frontend \
  -o jsonpath='{.spec.rules[0].from[0].source.principals}{"\n"}'
# Expected: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]

printf '\n== 2b. Allow rules — ingress+frontend -> api (count = 2) ==\n'
kubectl --context docker-desktop -n bookstore-api get authorizationpolicy allow-ingress-and-frontend-to-api \
  -o jsonpath='{.spec.rules[0].from[0].source.principals}{"\n"}' | jq 'length'
# Expected: 2

# 3. The deny is taking effect — Envoy's RBAC listener filter is now wired.
printf '\n== 3. Envoy RBAC HTTP filter is wired on api inbound listener ==\n'
istioctl --context docker-desktop proxy-config listener \
  $(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1 | cut -d/ -f2).bookstore-api \
  --port 15006 -o json \
  | jq -r '..|.name? // empty' | grep -c 'envoy\.filters\.http\.rbac'
# Expected: >= 1

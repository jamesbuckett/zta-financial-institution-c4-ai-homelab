# 1. ConfigMap exists and contains the package declaration.
printf '\n== 1. opa-policy ConfigMap contains package zta.authz ==\n'
kubectl --context docker-desktop -n zta-policy get configmap opa-policy \
  -o jsonpath='{.data.zta\.authz\.rego}' | grep -c '^package zta.authz'
# Expected: 1

# 2. OPA pod is Running with the new args (ext_authz gRPC + decision logs).
printf '\n== 2. OPA Deployment carries ext_authz + decision_logs args ==\n'
kubectl --context docker-desktop -n zta-policy get deploy opa \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | jq -r '.[]' | grep -E 'envoy_ext_authz_grpc|decision_logs.console'
# Expected (both lines):
#   --set=plugins.envoy_ext_authz_grpc.addr=:9191
#   --set=plugins.envoy_ext_authz_grpc.path=zta/authz/result
#   --set=decision_logs.console=true

# OPA ships in a distroless image (no wget/curl/shell) so we can't `kubectl
# exec` HTTP tools inside the OPA pod. Bridge the cluster API to the local
# host with kubectl port-forward and curl from outside instead.
printf '\n== 3. OPA REST /v1/policies lists the policy ==\n'
kubectl --context docker-desktop -n zta-policy port-forward svc/opa 18181:8181 >/dev/null 2>&1 &
PF=$!
trap "kill $PF 2>/dev/null || true" EXIT
# Wait for the local socket to accept; bail after ~10 s.
for _ in $(seq 1 20); do
  if curl -s --max-time 1 http://localhost:18181/health >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -s http://localhost:18181/v1/policies | jq -r '.result[].id'
# Expected: a path containing 'zta.authz.rego'

# 4. The package compiles inside OPA — query it and get a structured response.
printf '\n== 4. /v1/data/zta/authz/decision returns default-deny ==\n'
curl -s --data '{"input":{}}' --header 'Content-Type: application/json' \
  http://localhost:18181/v1/data/zta/authz/decision | jq '.result.allow, .result.reason'
# Expected:
#   false
#   "default-deny"

kill $PF 2>/dev/null || true
trap - EXIT

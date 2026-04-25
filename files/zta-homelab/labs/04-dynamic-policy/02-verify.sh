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

# 3. OPA's REST API reports the policy is loaded — query it directly.
printf '\n== 3. OPA REST /v1/policies lists the policy ==\n'
OPA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=opa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- http://localhost:8181/v1/policies | jq -r '.result[].id'
# Expected: a path containing 'zta.authz.rego'

# 4. The package compiles inside OPA — query it and get a structured response.
printf '\n== 4. /v1/data/zta/authz/decision returns default-deny ==\n'
kubectl --context docker-desktop -n zta-policy exec $OPA_POD -- \
  wget -qO- --post-data='{"input":{}}' --header='Content-Type: application/json' \
  http://localhost:8181/v1/data/zta/authz/decision | jq '.result.allow, .result.reason'
# Expected:
#   false
#   "default-deny"

# 1. Falco emitted the rule with priority >= notice.
printf '\n== 1. Falco emitted Terminal shell in container with k8s ns/pod ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --since=2m \
  | jq -c 'select(.rule=="Terminal shell in container") | {priority, k8s_ns: .output_fields["k8s.ns.name"], k8s_pod: .output_fields["k8s.pod.name"]}' \
  | head -1
# Expected: a JSON line with priority=Notice (or Warning/Critical) and k8s_ns=bookstore-api

# 2. CDM logs show it received the event and patched.
printf '\n== 2. CDM logs PATCHED ns=bookstore-api ... posture=tampered ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs deploy/cdm --since=2m \
  | grep -E 'PATCHED.*bookstore-api.*posture=tampered' | head -1
# Expected: a line containing PATCHED ns=bookstore-api ... posture=tampered

# 3. Pod annotation is now 'tampered' AND it carries the rule that fired.
printf '\n== 3. Pod annotation: posture=tampered, rule contains Terminal shell, at non-empty ==\n'
POD=$(kubectl --context docker-desktop -n bookstore-api get pod -l app=api -o name | head -1)
kubectl --context docker-desktop -n bookstore-api get $POD \
  -o jsonpath='{.metadata.annotations}' | jq '{posture: .["zta.posture"], rule: .["zta.posture.rule"], at: .["zta.posture.at"]}'
# Expected: posture=tampered, rule contains 'Terminal shell', at is non-empty

# 4. Posture flows to the wire: a fresh request now carries x-device-posture: tampered.
printf '\n== 4. frontend->api response shows X-Device-Posture: tampered ==\n'
FRONTEND=$(kubectl --context docker-desktop -n bookstore-frontend get pod -l app=frontend -o name | head -1)
sleep 5
kubectl --context docker-desktop -n bookstore-frontend exec $FRONTEND -c nginx -- \
  wget -qO- 'http://api.bookstore-api.svc.cluster.local/headers' \
  | jq -r '.headers["X-Device-Posture"]'
# Expected: tampered

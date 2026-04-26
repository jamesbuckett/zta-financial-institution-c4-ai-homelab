# 1. CDM Deployment ready, Service reachable on port 80.
printf '\n== 1. CDM Deployment 1/1 and Service exposes 80/8080 ==\n'
kubectl --context docker-desktop -n zta-runtime-security get deploy cdm \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

kubectl --context docker-desktop -n zta-runtime-security get svc cdm \
  -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}{"\n"}'
# Expected: 80/8080

# 2. RBAC is exactly the minimum needed (pods get/list/patch/watch — no more).
printf '\n== 2. ClusterRole verbs == [get,list,patch,watch]; can-i patch yes; can-i delete no ==\n'
kubectl --context docker-desktop get clusterrole cdm-patch-pods \
  -o jsonpath='{.rules[0].verbs}{"\n"}'
# Expected: ["get","list","patch","watch"]

kubectl --context docker-desktop auth can-i patch pods \
  --as=system:serviceaccount:zta-runtime-security:cdm -A
# Expected: yes

kubectl --context docker-desktop auth can-i delete pods \
  --as=system:serviceaccount:zta-runtime-security:cdm -A
# Expected: no   (CDM must NOT be able to delete — over-permissioning would break T5)

# 3. The CDM listens — POST a synthetic Falco event and confirm 204.
# Use 127.0.0.1 (not 'localhost') so we don't end up routing via ::1 — the
# python HTTPServer in the CDM image only binds IPv4 (0.0.0.0:8080), and
# busybox-wget's localhost resolves IPv6 first inside this image.
printf '\n== 3. CDM responds 204 to a synthetic Falco event ==\n'
CDM_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app=cdm -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $CDM_POD -- \
  wget -qO- --post-data='{"rule":"smoke","output_fields":{}}' \
  --header='Content-Type: application/json' \
  --server-response http://127.0.0.1:8080/ 2>&1 | grep -E 'HTTP/1\.[01] 204'
# Expected: a 'HTTP/1.x 204' line

# 1. PA deployment is Available — init container's opa-build succeeded.
printf '\n== 1. pa Deployment is 1/1 ready ==\n'
kubectl --context docker-desktop -n zta-policy get deploy pa \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
# Expected: 1/1

# 2. The init log proves opa build emitted a tarball.
printf '\n== 2. init container log shows built signed bundle ==\n'
kubectl --context docker-desktop -n zta-policy logs deploy/pa -c build --tail=20 \
  | grep -E 'built signed bundle|zta\.tar\.gz'
# Expected: a 'built signed bundle:' line and an ls entry showing zta.tar.gz

# 3. nginx is serving the bundle path with a non-zero Content-Length.
printf '\n== 3. nginx serves /bundles/zta.tar.gz with HTTP 200 ==\n'
PA_POD=$(kubectl --context docker-desktop -n zta-policy get pod -l app=pa -o name | head -1)
kubectl --context docker-desktop -n zta-policy exec $PA_POD -c nginx -- \
  wget -qS -O /dev/null http://localhost/bundles/zta.tar.gz 2>&1 \
  | grep -E 'HTTP/1\.[01] 200|Content-Length:'
# Expected: HTTP/1.1 200 and a Content-Length > 0

# 4. The bundle contains a .signatures.json file — proves the signer ran.
printf '\n== 4. Bundle tarball contains .signatures.json ==\n'
kubectl --context docker-desktop -n zta-policy exec $PA_POD -c nginx -- \
  sh -c 'tar -tzf /usr/share/nginx/html/bundles/zta.tar.gz' \
  | grep -E '^\.signatures\.json|signatures\.json'
# Expected: .signatures.json (or similar — the OPA bundle signing manifest)

# 5. Service routes to the PA (cluster IP populated, endpoints non-empty).
printf '\n== 5. Service opa-bundle-server has 1 endpoint ==\n'
kubectl --context docker-desktop -n zta-policy get endpoints opa-bundle-server \
  -o jsonpath='{.subsets[0].addresses[*].ip}{"\n"}' | wc -w
# Expected: 1   (one PA replica)

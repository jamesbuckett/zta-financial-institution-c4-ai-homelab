# 1. DaemonSet matches node count — every node has Falco; no monitoring gaps.
printf '\n== 1. Falco DaemonSet ready count matches node count ==\n'
NODES=$(kubectl --context docker-desktop get nodes --no-headers | wc -l)
READY=$(kubectl --context docker-desktop -n zta-runtime-security get ds falco \
          -o jsonpath='{.status.numberReady}')
echo "nodes=$NODES ready=$READY"
# Expected: nodes equals ready (e.g. nodes=1 ready=1 on Docker Desktop)

# 2. Driver reports as modern_ebpf and is loaded — not "skipped" / "fallback".
printf '\n== 2. modern_ebpf driver loaded ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=200 \
  | grep -E 'driver loaded|modern_ebpf' | head -2
# Expected: a 'modern_ebpf' line and a 'driver loaded' line

# 3. The default Falco rule set is loaded (Terminal shell in container is required by step 06).
printf '\n== 3. Default rules include Terminal shell in container ==\n'
kubectl --context docker-desktop -n zta-runtime-security logs ds/falco --tail=500 \
  | grep -c 'Terminal shell in container'
# Expected: >= 1   (rule will be referenced at engine startup or in tests)

# 4. Falco's metrics endpoint is up (T7 will scrape this in lab 7).
printf '\n== 4. Falco /healthz returns ok ==\n'
FALCO_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falco -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $FALCO_POD -- \
  wget -qO- http://localhost:8765/healthz
# Expected: ok   (or HTTP 200 body)

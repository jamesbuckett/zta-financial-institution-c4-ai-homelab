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

# 3. The default Falco rule set is loaded — required by step 06's "shell in
#    container" exercise. The rule name appears in stdout logs only when the
#    rule actually fires, so checking the logs is unreliable on a quiet
#    cluster. Inspect the rule file the falco container loaded at boot.
printf '\n== 3. Default rules include Terminal shell in container ==\n'
kubectl --context docker-desktop -n zta-runtime-security exec ds/falco -c falco -- \
  grep -c 'Terminal shell in container' /etc/falco/falco_rules.yaml
# Expected: >= 1   (Falco's bundled rule set declares the rule)

# 4. Falco's metrics endpoint is up (T7 will scrape this in lab 7).
# The falco image ships curl but not wget; -c falco selects the right
# container in the multi-container DaemonSet pod.
printf '\n== 4. Falco /healthz returns ok ==\n'
FALCO_POD=$(kubectl --context docker-desktop -n zta-runtime-security get pod -l app.kubernetes.io/name=falco -o name | head -1)
kubectl --context docker-desktop -n zta-runtime-security exec $FALCO_POD -c falco -- \
  curl -sf http://localhost:8765/healthz
# Expected: {"status":"ok"} or HTTP 200 body

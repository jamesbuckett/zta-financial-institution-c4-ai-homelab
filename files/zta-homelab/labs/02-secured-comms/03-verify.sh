# 1. Namespace exists and explicitly disables sidecar injection.
printf '\n== 1. zta-lab-debug namespace has istio-injection=disabled ==\n'
kubectl --context docker-desktop get ns zta-lab-debug \
  -o jsonpath='{.metadata.labels.istio-injection}{"\n"}'
# Expected: disabled

# 2. Pod is Running and has exactly ONE container — proves no sidecar was injected.
printf '\n== 2. debug pod is Running with one container (no sidecar) ==\n'
kubectl --context docker-desktop -n zta-lab-debug get pod debug \
  -o jsonpath='{.status.phase}{" "}{.spec.containers[*].name}{" count="}{range .spec.containers[*]}{.name}{","}{end}{"\n"}'
# Expected: Running tools count=tools,
#           (No "istio-proxy" sidecar — that is the whole point of this step.)

# 3. tcpdump is available and the capability bits really landed.
printf '\n== 3. tcpdump available and NET_RAW/NET_ADMIN capabilities present ==\n'
kubectl --context docker-desktop -n zta-lab-debug exec debug -- which tcpdump
# Expected: /usr/bin/tcpdump  (or /usr/sbin/tcpdump)
kubectl --context docker-desktop -n zta-lab-debug get pod debug \
  -o jsonpath='{.spec.containers[0].securityContext.capabilities.add}{"\n"}'
# Expected: ["NET_RAW","NET_ADMIN"]

# 1. Capture file exists and is non-empty — tcpdump actually saw frames.
printf '\n== 1. /tmp/capture.txt is non-empty ==\n'
test -s /tmp/capture.txt && echo "bytes=$(wc -c < /tmp/capture.txt)"
# Expected: bytes=>0

# 2. NO plaintext HTTP method or HTTP-style header on the wire.
printf '\n== 2. No plaintext HTTP verbs / headers in capture ==\n'
grep -cE '^(GET|POST|PUT|DELETE) /|Host: |User-Agent: ' /tmp/capture.txt
# Expected: 0

# 3. TLS record bytes ARE present in the payload — handshake (0x16) or
#    application-data (0x17) records, version TLS 1.2 (0x0303) or 1.0 (0x0301
#    for the very first ClientHello). The bytes appear at variable offsets
#    inside tcpdump -X hex lines (the IP/TCP header consumes the first
#    ~0x0028 bytes), so we don't anchor on 0x0000:. The grep tolerates the
#    space tcpdump inserts between hex byte pairs (e.g. `1703 03`).
printf '\n== 3. TLS record bytes present in capture ==\n'
grep -cE '1[67]03 ?0[13]' /tmp/capture.txt
# Expected: >= 1   (multiple TLS application-data records per request)

# 4. Wire-level destination port 8080 appears as a flow target — confirms
#    traffic actually reached the api endpoint port (not a service-port
#    bypass) and that we captured the inter-pod hop the sidecar produced.
#    The Istio inbound listener (15006) is NOT on the wire; it sits behind
#    the api pod's iptables REDIRECT and is only visible from inside that
#    pod's netns.
printf '\n== 4. api endpoint port 8080 visible in capture ==\n'
grep -cE '\.8080:' /tmp/capture.txt
# Expected: >= 1

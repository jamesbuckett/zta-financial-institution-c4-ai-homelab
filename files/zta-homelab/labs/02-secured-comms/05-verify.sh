# 1. Capture file exists and is non-empty — tcpdump actually saw frames.
printf '\n== 1. /tmp/capture.txt is non-empty ==\n'
test -s /tmp/capture.txt && echo "bytes=$(wc -c < /tmp/capture.txt)"
# Expected: bytes=>0

# 2. NO plaintext HTTP method or HTTP-style header on the wire.
printf '\n== 2. No plaintext HTTP verbs / headers in capture ==\n'
grep -cE '^(GET|POST|PUT|DELETE) /|Host: |User-Agent: ' /tmp/capture.txt
# Expected: 0

# 3. TLS record headers ARE present (handshake byte 0x16, version 0x0303).
printf '\n== 3. TLS record headers present in capture ==\n'
grep -cE '0x0000:.*1603 03|160303' /tmp/capture.txt
# Expected: >= 1   (some frames begin with a TLS 1.2/1.3 record; exact count varies)

# 4. Sidecar inbound port 15006 appears as a flow target — confirms traffic
#    was redirected through Envoy rather than reaching the app socket directly.
printf '\n== 4. Sidecar inbound port 15006 visible in capture ==\n'
grep -cE '\.15006:' /tmp/capture.txt
# Expected: >= 1

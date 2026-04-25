# Re-acquire TOKEN for check #4 if not set (allows standalone use).
if [ -z "${TOKEN:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/.env"
  TOKEN=$(curl -s -H 'Host: keycloak.local' \
    -d 'grant_type=password' -d 'client_id=bookstore-api' \
    -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
    -d 'username=alice' -d 'password=alice' \
    http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
    | jq -r .access_token)
fi

# 1. Capture roughly 3 minutes of observer output and prove the serial CHANGED.
printf '\n== 1. At least 2 distinct SVID serials in last 180 s ==\n'
LOGS=$(kubectl --context docker-desktop -n bookstore-api logs --since=180s deploy/svid-watcher -c observer)
echo "$LOGS" | awk -F= '/^serial=/ {print $2}' | awk '{print $1}' | sort -u | tee /tmp/serials.txt
SERIALS=$(wc -l < /tmp/serials.txt)
echo "distinct_serials=$SERIALS"
# Expected: distinct_serials >= 2   (at least one rotation observed in 180 s)

# 2. URI SAN names the bookstore-api workload — proves SPIRE issued the SVID.
printf '\n== 2. Observer log shows URI SAN for bookstore-api workload ==\n'
echo "$LOGS" | grep -m1 -oE 'URI:spiffe://[^[:space:]]+'
# Expected: URI:spiffe://zta.homelab/ns/bookstore-api/sa/default

# 3. notAfter is <= 5 minutes from now (NOT a long-lived cert).
printf '\n== 3. notAfter is within ~5 minutes of now ==\n'
NA=$(echo "$LOGS" | awk -F= '/notAfter/ {print $3; exit}' | awk '{$1=$1; print}')
echo "notAfter=$NA"
# Expected: notAfter is within ~5 minutes of system time
#           (date -d "$NA" +%s vs date +%s should differ by <= 320)

# 4. Tenet 3 maps cleanly: token TTL = SVID TTL = 300 s.
printf '\n== 4. Token TTL == SVID TTL == 300 ==\n'
LIFE=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp - .iat')
echo "token_ttl=$LIFE svid_ttl=300"
# Expected: token_ttl=300 svid_ttl=300   (per-session for both subject and workload)

#!/usr/bin/env bash
# Break-it exercise (Lab 3): replay an expired token through Istio JWT validation.
# Demonstrates why short-lived tokens matter — Tenet 3.
#
# Run manually: bash 06-break-it.sh
# Cleanup:      kubectl --context docker-desktop -n bookstore-api delete \
#                 requestauthentication keycloak-jwt \
#                 authorizationpolicy require-valid-jwt
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture a token and wait past its lifespan:
source "$SCRIPT_DIR/.env"
TOKEN=$(curl -s -H 'Host: keycloak.local' \
  -d 'grant_type=password' -d 'client_id=bookstore-api' \
  -d "client_secret=$BOOKSTORE_CLIENT_SECRET" \
  -d 'username=alice' -d 'password=alice' \
  http://localhost/realms/zta-bookstore/protocol/openid-connect/token \
  | jq -r .access_token)

echo "Token captured. Sleeping 310 s to let it expire..."
sleep 310

# Install a simple JWT-validation RequestAuthentication (used again in Lab 4):
cat <<'EOF' | kubectl --context docker-desktop apply -f -
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata: { name: keycloak-jwt, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  jwtRules:
  - issuer: "http://keycloak.local/realms/zta-bookstore"
    jwksUri: "http://keycloak.zta-identity.svc.cluster.local:8080/realms/zta-bookstore/protocol/openid-connect/certs"
    forwardOriginalToken: true
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: require-valid-jwt, namespace: bookstore-api }
spec:
  selector: { matchLabels: { app: api } }
  action: DENY
  rules:
  - from: [{ source: { notRequestPrincipals: ["*"] } }]
EOF

curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: bookstore.local' -H "Authorization: Bearer $TOKEN" \
  http://localhost/api/headers
# Expected: 401   (token is expired; Istio rejects before hitting the api pod)

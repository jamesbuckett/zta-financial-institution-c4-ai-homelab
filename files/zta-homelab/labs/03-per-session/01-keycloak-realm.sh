#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KC_POD=$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1)

kc() { kubectl --context $CTX -n zta-identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh "$@"; }

# Tolerate "already exists" on re-run.
kc_create_ok() {
  if ! out=$(kc "$@" 2>&1); then
    if echo "$out" | grep -qiE 'already exists|conflict|409'; then
      echo "(exists, continuing) $*"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
  echo "$out"
}

kc config credentials --server http://localhost:8080 --realm master --user admin --password admin

kc_create_ok create realms -s realm=zta-bookstore -s enabled=true \
  -s accessTokenLifespan=300 \
  -s ssoSessionIdleTimeout=1800 \
  -s ssoSessionMaxLifespan=3600

kc_create_ok create clients -r zta-bookstore -s clientId=bookstore-api \
  -s protocol=openid-connect -s publicClient=false \
  -s 'redirectUris=["http://bookstore.local/*"]' \
  -s directAccessGrantsEnabled=true \
  -s serviceAccountsEnabled=false

CID=$(kc get clients -r zta-bookstore -q clientId=bookstore-api --fields id --format csv --noquotes | tail -1)
kc update clients/$CID -r zta-bookstore -s 'attributes."access.token.lifespan"=300'
SECRET=$(kc get clients/$CID/client-secret -r zta-bookstore --fields value --format csv --noquotes | tail -1)

kc_create_ok create users -r zta-bookstore -s username=alice -s enabled=true -s email=alice@zta.homelab
kc set-password -r zta-bookstore --username alice --new-password alice

echo "BOOKSTORE_CLIENT_SECRET=$SECRET" > "$SCRIPT_DIR/.env"
echo "Realm ready. Secret stored in $SCRIPT_DIR/.env"

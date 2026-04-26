#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KC_POD=$(kubectl --context $CTX -n zta-identity get pod -l app=keycloak -o name | head -1)

kc() { kubectl --context $CTX -n zta-identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh "$@"; }

# Tolerate the various "this resource already exists" wordings kcadm.sh emits
# on re-run: realm/client say "already exists", users say "User exists with
# same username/email", and 409 may surface as a raw HTTP code on some paths.
kc_create_ok() {
  if ! out=$(kc "$@" 2>&1); then
    if echo "$out" | grep -qiE 'already exists|exists with same|conflict|409'; then
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

# firstName + lastName are required by Keycloak's User Profile feature (default
# in 25+). Without them, password grant fails with
#   "error":"invalid_grant","error_description":"Account is not fully set up"
# because the profile attributes get evaluated as missing-required when the
# token's profile scope is built.
# emailVerified=true is set explicitly so the realm can later be flipped to
# verifyEmail=true without re-breaking direct grant.
kc_create_ok create users -r zta-bookstore \
  -s username=alice -s enabled=true \
  -s email=alice@zta.homelab -s emailVerified=true \
  -s firstName=Alice -s lastName=Bookworm

# Re-run guard: a user created by an earlier (broken) version of this script
# may exist without firstName/lastName. Patch in the required profile fields
# unconditionally so the orchestrator is idempotent across the fix boundary.
ALICE_ID=$(kc get users -r zta-bookstore -q username=alice --fields id --format csv --noquotes | tail -1)
kc update users/$ALICE_ID -r zta-bookstore \
  -s emailVerified=true -s firstName=Alice -s lastName=Bookworm

kc set-password -r zta-bookstore --username alice --new-password alice

echo "BOOKSTORE_CLIENT_SECRET=$SECRET" > "$SCRIPT_DIR/.env"
echo "Realm ready. Secret stored in $SCRIPT_DIR/.env"

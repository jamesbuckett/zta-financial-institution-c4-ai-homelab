#!/usr/bin/env bash
# refresh-env.sh — re-derive BOOKSTORE_CLIENT_SECRET from Keycloak and
# rewrite .env. Idempotent. Silent no-op if Keycloak isn't reachable, so
# callers can invoke this defensively before sourcing .env without
# becoming brittle.
#
# Why this exists: Lab 3's installer wrote .env on the run that created
# the realm, but if Keycloak was later restarted (or its DB reset, or
# `./install.sh --from N` skipped Lab 3), the in-cluster secret drifts
# from .env. A stale secret silently yields a `null` access_token from
# Keycloak's password-grant endpoint — downstream curls then send
# `Authorization: Bearer null`, which the policy still denies (correct
# on the surface) but Lab 4's OPA `result` rule needs `claims.sub` for
# `decision_id`, so the decision-log entry has `result: null`. Verifies
# in Labs 5/6/7 that assert on x-zta-decision-reason then fail in
# confusing ways unrelated to the actual cause (.env staleness).
set -u
KCTX="${KCTX:-docker-desktop}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

KC_POD=$(kubectl --context "$KCTX" -n zta-identity get pod -l app=keycloak -o name 2>/dev/null | head -1)
[ -n "$KC_POD" ] || exit 0

KC_SECRET=$(kubectl --context "$KCTX" -n zta-identity exec -i "$KC_POD" -- sh -c \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null 2>&1 \
   && cid=$(/opt/keycloak/bin/kcadm.sh get clients -r zta-bookstore -q clientId=bookstore-api --fields id --format csv --noquotes | tail -1) \
   && /opt/keycloak/bin/kcadm.sh get clients/$cid/client-secret -r zta-bookstore --fields value --format csv --noquotes | tail -1' \
  2>/dev/null)
[ -n "$KC_SECRET" ] && [ "$KC_SECRET" != "null" ] || exit 0
echo "BOOKSTORE_CLIENT_SECRET=$KC_SECRET" > "$ENV_FILE"

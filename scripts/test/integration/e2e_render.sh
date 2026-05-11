#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PREFLIGHT_FILE=""

cleanup() {
  if [[ -n "$PREFLIGHT_FILE" && -f "$PREFLIGHT_FILE" ]]; then
    rm -f "$PREFLIGHT_FILE"
  fi
}

trap cleanup EXIT

###############################################################################
# SAFETY GATE: Render E2E protection
#
# Running E2E tests against Render creates real data in production-like DBs.
# This guard requires explicit confirmation before proceeding.
###############################################################################

ALLOW_RENDER_E2E="${ALLOW_RENDER_E2E:-}"
REQUIRED_RENDER_CONFIRMATION="I_UNDERSTAND_THIS_WRITES_TO_RENDER"

if [[ "$ALLOW_RENDER_E2E" != "$REQUIRED_RENDER_CONFIRMATION" ]]; then
  cat <<BANNER

╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║  WARNING: This script writes to Render production-like databases.        ║
║                                                                          ║
║  It will CREATE real users, products, carts, orders, and payments.       ║
║  These are E2E test artifacts with @test.local emails and SDD7/SDD9      ║
║  product names, but they pollute the shared Render databases.            ║
║                                                                          ║
║  Consider running against local instead:                                 ║
║    ./scripts/test/integration/e2e_local.sh                               ║
║                                                                          ║
║  If you truly need to run against Render, set:                           ║
║    export ALLOW_RENDER_E2E="I_UNDERSTAND_THIS_WRITES_TO_RENDER"          ║
║                                                                          ║
║  After running, clean up with:                                           ║
║    ./scripts/maintenance/cleanup_e2e_dry_run.sh                          ║
║    ./scripts/maintenance/cleanup_e2e_apply.sh                            ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

BANNER
  exit 1
fi

echo "[e2e][render] Render E2E confirmation accepted. Proceeding..."

# Load local env vars if present
# shellcheck disable=SC1091
if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
  source "$PLATFORM_ROOT/.env.local"
fi

export API_BASE="https://bazaar-backend-api-gateway.onrender.com"
export AUTH_BASE="https://bazaar-backend-auth-service.onrender.com"
export USER_BASE="https://bazaar-backend-user-service.onrender.com"
export CATALOG_BASE="https://bazaar-backend-catalog-service.onrender.com"
export CART_BASE="https://bazaar-backend-cart-service.onrender.com"
export ORDER_BASE="https://bazaar-backend-order-service.onrender.com"
export PAYMENT_BASE="https://bazaar-backend-payment-service.onrender.com"

export AUTH_SERVICE_URL="$AUTH_BASE"
export USER_SERVICE_URL="$USER_BASE"
export CATALOG_SERVICE_URL="$CATALOG_BASE"
export CART_SERVICE_URL="$CART_BASE"
export ORDER_SERVICE_URL="$ORDER_BASE"
export PAYMENT_SERVICE_URL="$PAYMENT_BASE"
export PAYMENTS_SERVICE_URL="$PAYMENT_BASE"

export INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
export CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"

export PASSWORD="${PASSWORD:-}"
export PAYMENT_SIMULATION_MODE="approved"

echo "[e2e][render] Checking cart-service internal token..."
PREFLIGHT_FILE="$(mktemp)"
preflight_code="$(curl -sS -o "$PREFLIGHT_FILE" -w '%{http_code}' \
  -X POST "$CART_BASE/internal/checkout-cleanup" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Service-Token: $CART_INTERNAL_SERVICE_TOKEN" \
  --data '{"buyer_id":999999999,"checkout_group_id":"11111111-1111-1111-1111-111111111111","items":[{"product_id":1,"quantity":1}]}')"

if [[ "$preflight_code" == "401" || "$preflight_code" == "403" ]]; then
  echo "[e2e][render][error] cart-service rejected the internal token with HTTP $preflight_code"
  echo "[e2e][render][error] Response:"
  cat "$PREFLIGHT_FILE"
  echo
  echo "[e2e][render][fix required in Render]"
  echo "In bazaar-backend-cart-service, add/update:"
  echo " INTERNAL_SERVICE_TOKEN=$INTERNAL_SERVICE_TOKEN"
  echo
  echo "In bazaar-backend-order-service, verify:"
  echo " INTERNAL_SERVICE_TOKEN=$INTERNAL_SERVICE_TOKEN"
  echo " CART_SERVICE_URL=$CART_SERVICE_URL"
  echo
  echo "Then redeploy cart-service first, then order-service."
  exit 1
fi

if [[ "$preflight_code" =~ ^2[0-9][0-9]$ ]]; then
  echo "[e2e][render][ok] cart-service internal token accepted with HTTP $preflight_code"
else
  echo "[e2e][render][warn] cart-service preflight returned HTTP $preflight_code"
  echo "[e2e][render][warn] Body:"
  cat "$PREFLIGHT_FILE" || true
  echo
  echo "[e2e][render][warn] Continuing because this is not an auth rejection."
fi

"$SCRIPT_DIR/_e2e_checkout.sh"

#!/usr/bin/env bash
set -euo pipefail

# Load local env vars if present
if [[ -f ".env.local" ]]; then
  source ".env.local"
elif [[ -f "$(dirname "$0")/../../../.env.local" ]]; then
  source "$(dirname "$0")/../../../.env.local"
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

# Ensure these are provided by .env.local
export INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
export CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"

export JWT_SECRET="${JWT_SECRET:-}"
export PASSWORD="${PASSWORD:-}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@bazaar.dev}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
export PAYMENT_SIMULATION_MODE="approved"

echo "[sdd7] Checking cart-service internal token..."
preflight_code="$(
  curl -sS -o /tmp/sdd7-cart-internal-preflight.json -w '%{http_code}' \
    -X POST "$CART_BASE/internal/checkout-cleanup" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Internal-Service-Token: $CART_INTERNAL_SERVICE_TOKEN" \
    --data '{"buyer_id":999999999,"checkout_group_id":"11111111-1111-1111-1111-111111111111","items":[{"product_id":1,"quantity":1}]}'
)"

if [[ "$preflight_code" == "401" || "$preflight_code" == "403" ]]; then
  echo "[sdd7][error] cart-service rejected the internal token with HTTP $preflight_code"
  echo "[sdd7][error] Response:"
  cat /tmp/sdd7-cart-internal-preflight.json
  echo
  echo "[sdd7][fix required in Render]"
  echo "In bazaar-backend-cart-service, add/update:"
  echo "  INTERNAL_SERVICE_TOKEN=$INTERNAL_SERVICE_TOKEN"
  echo
  echo "In bazaar-backend-order-service, verify:"
  echo "  INTERNAL_SERVICE_TOKEN=$INTERNAL_SERVICE_TOKEN"
  echo "  CART_SERVICE_URL=$CART_SERVICE_URL"
  echo
  echo "Then redeploy cart-service first, then order-service."
  exit 1
fi

if [[ "$preflight_code" =~ ^2[0-9][0-9]$ ]]; then
  echo "[sdd7][ok] cart-service internal token accepted with HTTP $preflight_code"
else
  echo "[sdd7][warn] cart-service preflight returned HTTP $preflight_code"
  echo "[sdd7][warn] Body:"
  cat /tmp/sdd7-cart-internal-preflight.json || true
  echo
  echo "[sdd7][warn] Continuing because this is not an auth rejection."
fi

"$(dirname "$0")/e2e_render_checkout_saga_sdd7.sh"

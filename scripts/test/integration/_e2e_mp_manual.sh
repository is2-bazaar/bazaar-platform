#!/usr/bin/env bash
# _e2e_mp_manual.sh — Mercado Pago manual testing script
# Creates test data and initiates checkout, then prints instructions
# for completing payment in MP sandbox manually.
#
# Prerequisites:
#   - Stack running: ./scripts/up.sh
#   - PAYMENT_PROVIDER=mercadopago (set in .env.local or env)
#   - MERCADOPAGO_ACCESS_TOKEN (sandbox TEST- token)
#   - ngrok tunnel active for webhook delivery
#
# This script does NOT attempt to pay automatically.
# It extracts the payment_url and prints manual steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load platform env
# shellcheck disable=SC1091
source "$PLATFORM_ROOT/scripts/common.sh"
load_platform_env

# Service URLs
API_BASE="${API_BASE:-$LOCAL_API_BASE_URL}"
ORDER_BASE="${ORDER_BASE:-http://localhost:${ORDER_SERVICE_HOST_PORT:-18086}}"
PAYMENT_BASE="${PAYMENT_BASE:-http://localhost:${PAYMENT_SERVICE_HOST_PORT:-18084}}"
CART_BASE="${CART_BASE:-http://localhost:${CART_SERVICE_HOST_PORT:-18085}}"
CATALOG_BASE="${CATALOG_BASE:-http://localhost:${CATALOG_SERVICE_HOST_PORT:-18083}}"
AUTH_BASE="${AUTH_BASE:-http://localhost:${AUTH_SERVICE_HOST_PORT:-18081}}"

INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
PASSWORD="${PASSWORD:-E2eMp1234!}"
RUN_ID="mp-$(date +%s)"

OUT_DIR="tmp/e2e-mp-${RUN_ID}"
HTTP_DIR="$OUT_DIR/http"
STATE_DIR="$OUT_DIR/state"
mkdir -p "$HTTP_DIR" "$STATE_DIR"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[34m%s\033[0m\n" "$*"; }

die() {
  red "[FATAL] $*"
  exit 1
}

http_req() {
  local label="$1"; local method="$2"; local url="$3"; local payload="${4:-}"; shift 4 || true
  local headers_file="$HTTP_DIR/$label.headers"
  local body_file="$HTTP_DIR/$label.json"
  local code_file="$HTTP_DIR/$label.code"

  local args=(curl -sS -X "$method" "$url" -D "$headers_file" -o "$body_file" -w '%{http_code}' -H "Accept: application/json")
  [[ -n "$payload" ]] && args+=(-H "Content-Type: application/json" --data "$payload")
  local h
  for h in "$@"; do
    [[ -n "$h" ]] && args+=(-H "$h")
  done

  local code
  code="$("${args[@]}" 2>/dev/null || printf "000")"
  printf '%s' "$code" >"$code_file"
  printf '%s' "$code"
}

json_val() {
  local file="$1"; local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
file_path = sys.argv[1]
expr = sys.argv[2].strip()
if expr.startswith("."): expr = expr[1:]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(""); sys.exit(0)
cur = data
for part in expr.split("."):
    if not part: continue
    if not isinstance(cur, dict) or part not in cur:
        print(""); sys.exit(0)
    cur = cur[part]
if cur is None: print("")
elif isinstance(cur, bool): print("true" if cur else "false")
elif isinstance(cur, (dict, list)): print(json.dumps(cur, ensure_ascii=False))
else: print(cur)
PY
}

# -------------------------------------------------------------------
# Pre-flight
# -------------------------------------------------------------------
echo ""
blue "============================================"
blue "  Mercado Pago Manual E2E Test"
blue "  RUN_ID: $RUN_ID"
blue "============================================"
echo ""

green "[1/5] Verifying services..."
for svc in auth catalog cart order payment gateway; do
  case "$svc" in
    auth)     url="$AUTH_BASE/readyz" ;;
    catalog)  url="$CATALOG_BASE/readyz" ;;
    cart)     url="$CART_BASE/readyz" ;;
    order)    url="$ORDER_BASE/readyz" ;;
    payment)  url="$PAYMENT_BASE/readyz" ;;
    gateway)  url="$API_BASE/livez" ;;
  esac
  code="$(http_req "ready-$svc" GET "$url")"
  if [[ "$code" == "200" ]]; then
    green "  $svc: OK"
  else
    die "$svc not ready (HTTP $code). Run ./scripts/up.sh first."
  fi
done

# -------------------------------------------------------------------
# 1. Create buyer user
# -------------------------------------------------------------------
green "[2/5] Creating buyer user..."
BUYER_USER="buyer-mp-$(( RANDOM % 9000 + 1000 ))"
BUYER_EMAIL="${BUYER_USER}@test.local"

buyer_code="$(http_req "register-buyer" POST "$API_BASE/auth/register" \
  "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASSWORD\",\"username\":\"$BUYER_USER\"}")"

if [[ "$buyer_code" != "201" ]]; then
  die "Buyer registration failed: HTTP $buyer_code"
fi

BUYER_TOKEN="$(json_val "$HTTP_DIR/register-buyer.json" ".access_token")"
BUYER_ID="$(json_val "$HTTP_DIR/register-buyer.json" ".user_id")"
green "  Buyer: $BUYER_EMAIL (id=$BUYER_ID)"

# -------------------------------------------------------------------
# 2. Create seller + product
# -------------------------------------------------------------------
green "[3/5] Creating seller and product..."
SELLER_USER="seller-mp-$(( RANDOM % 9000 + 1000 ))"
SELLER_EMAIL="${SELLER_USER}@test.local"

seller_code="$(http_req "register-seller" POST "$API_BASE/auth/register" \
  "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$PASSWORD\",\"username\":\"$SELLER_USER\"}")"

if [[ "$seller_code" != "201" ]]; then
  die "Seller registration failed: HTTP $seller_code"
fi

SELLER_TOKEN="$(json_val "$HTTP_DIR/register-seller.json" ".access_token")"
SELLER_ID="$(json_val "$HTTP_DIR/register-seller.json" ".user_id")"
green "  Seller: $SELLER_EMAIL (id=$SELLER_ID)"

# Create product
PRODUCT_LABEL="MP-test-${RUN_ID}"
product_code="$(http_req "create-product" POST "$API_BASE/catalog/me/products" \
  "{\"name\":\"$PRODUCT_LABEL\",\"description\":\"MP test product\",\"price\":1500.00,\"stock_quantity\":10,\"image_bucket_url\":\"\",\"category\":\"technology\",\"status\":\"active\"}" \
  "Authorization: Bearer $SELLER_TOKEN" "Idempotency-Key: product-$PRODUCT_LABEL")"

if [[ "$product_code" != "201" && "$product_code" != "200" ]]; then
  die "Product creation failed: HTTP $product_code"
fi

PRODUCT_ID="$(json_val "$HTTP_DIR/create-product.json" ".id")"
green "  Product: $PRODUCT_LABEL (id=$PRODUCT_ID)"

# -------------------------------------------------------------------
# 3. Add to cart
# -------------------------------------------------------------------
green "[4/5] Adding product to cart..."
cart_code="$(http_req "cart-add" POST "$API_BASE/cart/items" \
  "{\"product_id\":$PRODUCT_ID,\"quantity\":1}" \
  "Authorization: Bearer $BUYER_TOKEN")"

if [[ "$cart_code" != "201" && "$cart_code" != "200" ]]; then
  die "Cart add failed: HTTP $cart_code"
fi
green "  Product added to cart."

# -------------------------------------------------------------------
# 4. Checkout
# -------------------------------------------------------------------
green "[5/5] Initiating checkout..."
IDEM_KEY="mp-checkout-${RUN_ID}"

checkout_code="$(http_req "checkout" POST "$API_BASE/checkout" \
  '{"delivery_address":"Av MP 123","delivery_city":"CABA","delivery_province":"Buenos Aires"}' \
  "Authorization: Bearer $BUYER_TOKEN" "Idempotency-Key: $IDEM_KEY")"

CHECKOUT_GROUP_ID="$(json_val "$HTTP_DIR/checkout.json" ".checkout_group_id")"
PAYMENT_URL="$(json_val "$HTTP_DIR/checkout.json" ".payment_url")"
CHECKOUT_STATUS="$(json_val "$HTTP_DIR/checkout.json" ".status")"

if [[ "$checkout_code" != "201" ]]; then
  yellow "  Checkout returned HTTP $checkout_code (expected 201 for pending)"
  body="$(tr '\n' ' ' < "$HTTP_DIR/checkout.json")"
  yellow "  Body: $body"
fi

green "  Checkout group: $CHECKOUT_GROUP_ID"
green "  Status: $CHECKOUT_STATUS"

# -------------------------------------------------------------------
# Results
# -------------------------------------------------------------------
echo ""
blue "============================================"
blue "  RESULTS"
blue "============================================"
echo ""
echo "BUYER_EMAIL:      $BUYER_EMAIL"
echo "BUYER_PASSWORD:   $PASSWORD"
echo "SELLER_EMAIL:     $SELLER_EMAIL"
echo "PRODUCT_ID:       $PRODUCT_ID"
echo "CHECKOUT_GROUP_ID: $CHECKOUT_GROUP_ID"
echo "IDEMPOTENCY_KEY:  $IDEM_KEY"
echo ""

if [[ -n "$PAYMENT_URL" && "$PAYMENT_URL" != "null" ]]; then
  echo "PAYMENT_URL:      $PAYMENT_URL"
  echo ""
  blue "============================================"
  blue "  MANUAL STEPS"
  blue "============================================"
  echo ""
  echo "1. Open the payment URL in your browser:"
  yellow "   $PAYMENT_URL"
  echo ""
  echo "2. Complete payment using Mercado Pago sandbox test cards:"
  echo "   - Visa:       4509 9535 6623 3704"
  echo "   - Mastercard: 5031 7557 3453 0604"
  echo "   - Amex:       3700 0000 0000 002"
  echo "   - Expiry:     any future date"
  echo "   - CVV:        any 3 digits"
  echo "   - DNI:        any number"
  echo ""
  echo "3. After payment, the webhook will confirm the order automatically."
  echo "   (Requires ngrok tunnel + PAYMENT_WEBHOOK_URL configured)"
  echo ""
  echo "4. Check checkout group status:"
  echo ""
  green "   http_req \"checkout-status\" GET \"$API_BASE/checkout-groups/$CHECKOUT_GROUP_ID\" \"\" \"Authorization: Bearer \$BUYER_TOKEN\""
  echo ""
  echo "   Or with curl:"
  echo ""
  green "   curl -s \"$API_BASE/checkout-groups/$CHECKOUT_GROUP_ID\" -H \"Authorization: Bearer $BUYER_TOKEN\" | python3 -m json.tool"
  echo ""
  blue "============================================"
else
  yellow "No payment_url found in response. Checkout may have resolved immediately."
  yellow "Check the response file: $HTTP_DIR/checkout.json"
fi

echo ""
echo "Raw outputs: $HTTP_DIR/"
echo "Done."

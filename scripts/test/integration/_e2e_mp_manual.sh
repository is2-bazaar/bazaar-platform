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
# Modes:
#   checkout (default) — Create buyer/seller/product, checkout, print MP URL
#   ./scripts/test/integration/_e2e_mp_manual.sh checkout
#
#   verify CHECKOUT_GROUP_ID BUYER_TOKEN — Query state and display results
#   ./scripts/test/integration/_e2e_mp_manual.sh verify <CHECKOUT_GROUP_ID> <BUYER_TOKEN>
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
mkdir -p "$HTTP_DIR"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
red() { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue() { printf "\033[34m%s\033[0m\n" "$*"; }

die() {
  red "[FATAL] $*"
  exit 1
}

http_req() {
  local label="$1"
  local method="$2"
  local url="$3"
  local payload="${4:-}"
  shift 4 || true
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
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
file_path = sys.argv[1]
expr = sys.argv[2].strip()
if expr.startswith("."): expr = expr[1:]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("ERROR: JSON parse failed", file=sys.stderr)
    sys.exit(1)
cur = data
for part in expr.split("."):
    if not part: continue
    if not isinstance(cur, dict) or part not in cur:
        print(f"ERROR: field '{expr}' not found in JSON", file=sys.stderr)
        sys.exit(1)
    cur = cur[part]
if cur is None:
    print("null")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
PY
}

# -------------------------------------------------------------------
# Pre-flight validation
# -------------------------------------------------------------------
validate_startup() {
  local provider="${PAYMENT_PROVIDER:-}"
  local mp_token="${MERCADOPAGO_ACCESS_TOKEN:-}"
  local webhook_url="${PAYMENT_WEBHOOK_URL:-}"
  local internal_token="${INTERNAL_SERVICE_TOKEN:-}"

  if [[ "$provider" != "mercadopago" ]]; then
    die "PAYMENT_PROVIDER must be 'mercadopago', got '${provider:-unset}'"
  fi

  if [[ -z "$mp_token" ]]; then
    die "MERCADOPAGO_ACCESS_TOKEN is not set or empty"
  fi

  if [[ "$webhook_url" != https://* ]]; then
    die "PAYMENT_WEBHOOK_URL must start with https:// (required by MP for webhook delivery), got '${webhook_url:-unset}'"
  fi

  if [[ -z "$internal_token" ]]; then
    die "INTERNAL_SERVICE_TOKEN is not set or empty"
  fi

  green "[validation] PAYMENT_PROVIDER=$provider"
  green "[validation] MERCADOPAGO_ACCESS_TOKEN=***${mp_token: -4}"
  green "[validation] PAYMENT_WEBHOOK_URL=$webhook_url"
  green "[validation] INTERNAL_SERVICE_TOKEN=***${internal_token: -4}"
}

# -------------------------------------------------------------------
# verify mode: query checkout group, buyer orders, cart, display state
# -------------------------------------------------------------------
do_verify() {
  local cgid="$1"
  local buyer_token="$2"

  echo ""
  blue "============================================"
  blue "  VERIFY MODE"
  blue "  Checkout Group: $cgid"
  blue "============================================"
  echo ""

  # Query checkout group
  green "[verify] Fetching checkout group..."
  echo ""
  echo "  curl -s \"${API_BASE}/checkout-groups/${cgid}\" \\"
  echo "    -H \"Authorization: Bearer ${buyer_token}\""
  echo ""
  http_req "verify-cg" GET "$API_BASE/checkout-groups/$cgid" "" "Authorization: Bearer $buyer_token"
  local cg_code
  cg_code="$(cat "$HTTP_DIR/verify-cg.code")"
  echo "  HTTP $cg_code"

  if [[ "$cg_code" == "200" ]]; then
    python3 -m json.tool "$HTTP_DIR/verify-cg.json" 2>/dev/null || cat "$HTTP_DIR/verify-cg.json"
  else
    yellow "  Response:"
    python3 -m json.tool "$HTTP_DIR/verify-cg.json" 2>/dev/null || cat "$HTTP_DIR/verify-cg.json"
  fi

  # Query buyer orders
  echo ""
  green "[verify] Fetching buyer orders..."
  echo ""
  echo "  curl -s \"${API_BASE}/orders/\" \\"
  echo "    -H \"Authorization: Bearer ${buyer_token}\""
  echo ""
  http_req "verify-orders" GET "$API_BASE/orders/" "" "Authorization: Bearer $buyer_token"
  local orders_code
  orders_code="$(cat "$HTTP_DIR/verify-orders.code")"
  echo "  HTTP $orders_code"

  if [[ "$orders_code" == "200" ]]; then
    local order_count
    order_count="$(python3 -c "
import json
with open('${HTTP_DIR}/verify-orders.json') as f:
    data = json.load(f)
orders = data.get('orders', data.get('data', {}).get('orders', []))
print(len(orders))
" 2>/dev/null || echo "0")"
    echo "  Order count: $order_count"
    python3 -m json.tool "$HTTP_DIR/verify-orders.json" 2>/dev/null || cat "$HTTP_DIR/verify-orders.json"
  else
    cat "$HTTP_DIR/verify-orders.json" 2>/dev/null || true
  fi

  # Query cart
  echo ""
  green "[verify] Fetching buyer cart..."
  echo ""
  echo "  curl -s \"${API_BASE}/cart/\" \\"
  echo "    -H \"Authorization: Bearer ${buyer_token}\""
  echo ""
  http_req "verify-cart" GET "$API_BASE/cart/" "" "Authorization: Bearer $buyer_token"
  local cart_code
  cart_code="$(cat "$HTTP_DIR/verify-cart.code")"
  echo "  HTTP $cart_code"

  if [[ "$cart_code" == "200" ]]; then
    local cart_items
    cart_items="$(python3 -c "
import json
with open('${HTTP_DIR}/verify-cart.json') as f:
    data = json.load(f)
items = data.get('items', data.get('data', {}).get('items', []))
print(len(items))
" 2>/dev/null || echo "0")"
    echo "  Cart item count: $cart_items"
    python3 -m json.tool "$HTTP_DIR/verify-cart.json" 2>/dev/null || cat "$HTTP_DIR/verify-cart.json"
  else
    cat "$HTTP_DIR/verify-cart.json" 2>/dev/null || true
  fi

  echo ""
  blue "============================================"
  green "  Verify complete. Raw outputs: $HTTP_DIR/"
  blue "============================================"
}

# -------------------------------------------------------------------
# Main: dispatch by mode
# -------------------------------------------------------------------
MODE="${1:-checkout}"

if [[ "$MODE" == "verify" ]]; then
  if [[ $# -lt 3 ]]; then
    die "Usage: $0 verify <CHECKOUT_GROUP_ID> <BUYER_TOKEN>"
  fi
  do_verify "$2" "$3"
  exit 0
fi

echo ""
blue "============================================"
blue "  Mercado Pago Manual E2E Test"
blue "  RUN_ID: $RUN_ID"
blue "============================================"
echo ""

validate_startup

green "[1/5] Verifying services..."
for svc in auth catalog cart order payment gateway; do
  case "$svc" in
    auth) url="$AUTH_BASE/readyz" ;;
    catalog) url="$CATALOG_BASE/readyz" ;;
    cart) url="$CART_BASE/readyz" ;;
    order) url="$ORDER_BASE/readyz" ;;
    payment) url="$PAYMENT_BASE/readyz" ;;
    gateway) url="$API_BASE/livez" ;;
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
BUYER_USER="buyer-mp-$((RANDOM % 9000 + 1000))"
BUYER_EMAIL="${BUYER_USER}@test.local"

buyer_code="$(http_req "register-buyer" POST "$API_BASE/auth/register" \
  "{\"email\":\"$BUYER_EMAIL\",\"password\":\"$PASSWORD\",\"username\":\"$BUYER_USER\"}")"

if [[ "$buyer_code" != "201" ]]; then
  die "Buyer registration failed: HTTP $buyer_code"
fi

BUYER_TOKEN="$(json_val "$HTTP_DIR/register-buyer.json" ".access_token")" || die "Failed to extract access_token from buyer registration"
BUYER_ID="$(json_val "$HTTP_DIR/register-buyer.json" ".user_id")" || die "Failed to extract user_id from buyer registration"
green "  Buyer: $BUYER_EMAIL (id=$BUYER_ID)"

# -------------------------------------------------------------------
# 2. Create seller + product
# -------------------------------------------------------------------
green "[3/5] Creating seller and product..."
SELLER_USER="seller-mp-$((RANDOM % 9000 + 1000))"
SELLER_EMAIL="${SELLER_USER}@test.local"

seller_code="$(http_req "register-seller" POST "$API_BASE/auth/register" \
  "{\"email\":\"$SELLER_EMAIL\",\"password\":\"$PASSWORD\",\"username\":\"$SELLER_USER\"}")"

if [[ "$seller_code" != "201" ]]; then
  die "Seller registration failed: HTTP $seller_code"
fi

SELLER_TOKEN="$(json_val "$HTTP_DIR/register-seller.json" ".access_token")" || die "Failed to extract access_token from seller registration"
SELLER_ID="$(json_val "$HTTP_DIR/register-seller.json" ".user_id")" || die "Failed to extract user_id from seller registration"
green "  Seller: $SELLER_EMAIL (id=$SELLER_ID)"

# Create product
PRODUCT_LABEL="MP-test-${RUN_ID}"
product_code="$(http_req "create-product" POST "$API_BASE/catalog/me/products" \
  "{\"name\":\"$PRODUCT_LABEL\",\"description\":\"MP test product\",\"price\":1500.00,\"stock_quantity\":10,\"image_bucket_url\":\"\",\"category\":\"technology\",\"status\":\"active\"}" \
  "Authorization: Bearer $SELLER_TOKEN" "Idempotency-Key: product-$PRODUCT_LABEL")"

if [[ "$product_code" != "201" && "$product_code" != "200" ]]; then
  die "Product creation failed: HTTP $product_code"
fi

PRODUCT_ID="$(json_val "$HTTP_DIR/create-product.json" ".id")" || die "Failed to extract id from product creation"
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

CHECKOUT_GROUP_ID="$(json_val "$HTTP_DIR/checkout.json" ".checkout_group_id")" || die "Failed to extract checkout_group_id from checkout response"
PAYMENT_URL="$(json_val "$HTTP_DIR/checkout.json" ".payment_url")" || die "Failed to extract payment_url from checkout response"
CHECKOUT_STATUS="$(json_val "$HTTP_DIR/checkout.json" ".status")" || die "Failed to extract status from checkout response"

if [[ "$checkout_code" != "201" ]]; then
  yellow "  Checkout returned HTTP $checkout_code (expected 201 for pending)"
  body="$(tr '\n' ' ' <"$HTTP_DIR/checkout.json")"
  yellow "  Body: $body"
fi

green "  Checkout group: $CHECKOUT_GROUP_ID"
green "  Status: $CHECKOUT_STATUS"

# -------------------------------------------------------------------
# Results — print real curl commands, not internal helper aliases
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
  green "   curl -s \"$API_BASE/checkout-groups/$CHECKOUT_GROUP_ID\" \\"
  green "     -H \"Authorization: Bearer \$BUYER_TOKEN\" | python3 -m json.tool"
  echo ""
  echo "5. Check buyer orders:"
  echo ""
  green "   curl -s \"$API_BASE/orders/\" \\"
  green "     -H \"Authorization: Bearer \$BUYER_TOKEN\" | python3 -m json.tool"
  echo ""
  echo "6. Check cart status:"
  echo ""
  green "   curl -s \"$API_BASE/cart/\" \\"
  green "     -H \"Authorization: Bearer \$BUYER_TOKEN\" | python3 -m json.tool"
  echo ""
  blue "============================================"
  echo ""
  echo "Quick verify with this script:"
  echo ""
  green "  $0 verify $CHECKOUT_GROUP_ID \"$BUYER_TOKEN\""
  echo ""
else
  yellow "No payment_url found in response. Checkout may have resolved immediately."
  yellow "Check the response file: $HTTP_DIR/checkout.json"
fi

echo ""
echo "Raw outputs: $HTTP_DIR/"
echo "Done."

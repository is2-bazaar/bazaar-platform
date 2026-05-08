#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Bazaar Render E2E — Checkout Saga / SDD 7
#
# Objetivo:
#   Validar SDD 7 sobre Render, sin DB directa:
#   - cart-service internal cleanup: POST /internal/checkout-cleanup
#   - idempotencia por checkout_group_id
#   - limpieza parcial por cantidad
#   - hard delete + re-add seguro
#   - cleanup integrado desde order-service luego de checkout approved
#   - retry de checkout no vuelve a limpiar items re-agregados
#
# Payment:
#   Se asume PAYMENT_SIMULATION_MODE=approved en Render payment-service.
#
# Uso:
#   ./scripts/e2e_render_checkout_saga_sdd7.sh
#
# Opcionales:
#   RUN_ID=123 ./scripts/e2e_render_checkout_saga_sdd7.sh
#   INTERNAL_SERVICE_TOKEN=... ./scripts/e2e_render_checkout_saga_sdd7.sh
###############################################################################

API_BASE="${API_BASE:-https://bazaar-backend-api-gateway.onrender.com}"
AUTH_BASE="${AUTH_BASE:-https://bazaar-backend-auth-service.onrender.com}"
USER_BASE="${USER_BASE:-https://bazaar-backend-user-service.onrender.com}"
CATALOG_BASE="${CATALOG_BASE:-https://bazaar-backend-catalog-service.onrender.com}"
CART_BASE="${CART_BASE:-https://bazaar-backend-cart-service.onrender.com}"
ORDER_BASE="${ORDER_BASE:-https://bazaar-backend-order-service.onrender.com}"
PAYMENT_BASE="${PAYMENT_BASE:-https://bazaar-backend-payment-service.onrender.com}"

# Load local env vars if present
if [[ -f ".env.local" ]]; then
  source ".env.local"
elif [[ -f "$(dirname "$0")/../../../.env.local" ]]; then
  source "$(dirname "$0")/../../../.env.local"
fi

INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"
PASSWORD="${PASSWORD:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@bazaar.dev}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
RUN_ID="${RUN_ID:-$(date +%s)}"

OUT_DIR="tmp/e2e-render-checkout-saga-sdd7-${RUN_ID}"
HTTP_DIR="$OUT_DIR/http"
STATE_DIR="$OUT_DIR/state"
REPORT="$OUT_DIR/REPORT.md"
RESULTS="$OUT_DIR/results.tsv"

mkdir -p "$HTTP_DIR" "$STATE_DIR"
: > "$RESULTS"

PASS=0
FAIL=0
SKIP=0
USER_SEQ=0

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue() { printf "\033[34m%s\033[0m\n" "$*"; }

record() {
  local status="$1"
  local name="$2"
  local note="${3:-}"
  printf "%s\t%s\t%s\n" "$status" "$name" "$note" >> "$RESULTS"

  case "$status" in
    PASS) PASS=$((PASS+1)); green "PASS - $name - $note" ;;
    FAIL) FAIL=$((FAIL+1)); red "FAIL - $name - $note" ;;
    SKIP) SKIP=$((SKIP+1)); yellow "SKIP - $name - $note" ;;
  esac
}

state_put() { printf '%s' "$2" > "$STATE_DIR/$1"; }
state_get() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1"; }

body_flat() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tr '\n' ' ' < "$file" | sed 's/[[:space:]]\+/ /g' | sed 's/|/\//g'
}

json_get() {
  local file="$1"
  local expr="$2"

  python3 - "$file" "$expr" <<'PY'
import json, re, sys

file_path = sys.argv[1]
expr = sys.argv[2].strip()

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

if expr.startswith("."):
    expr = expr[1:]

def resolve(obj, path):
    cur = obj
    if not path:
        return cur
    for part in path.split("."):
        if not part:
            continue
        m = re.fullmatch(r"([A-Za-z0-9_]+)(\[(\d+)\])?", part)
        if not m:
            return ""
        key = m.group(1)
        idx = m.group(3)
        if not isinstance(cur, dict) or key not in cur:
            return ""
        cur = cur[key]
        if idx is not None:
            if not isinstance(cur, list):
                return ""
            i = int(idx)
            if i < 0 or i >= len(cur):
                return ""
            cur = cur[i]
    return cur

if expr.endswith(" | length"):
    base = expr[:-9].strip()
    if base.startswith("."):
        base = base[1:]
    value = resolve(data, base)
    try:
        print(len(value))
    except Exception:
        print("")
    sys.exit(0)

value = resolve(data, expr)
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

token_user_id() {
  local token="$1"

  python3 - "$token" <<'PY'
import base64, json, sys

token = sys.argv[1]
try:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload.encode()).decode())
except Exception:
    print("")
    sys.exit(0)

for key in ("user_id", "id", "sub"):
    value = claims.get(key)
    if value is None:
        continue
    value = str(value)
    if value.isdigit():
        print(value)
        sys.exit(0)

print("")
PY
}

json_find_product_id_by_name() {
  local file="$1"
  local target="$2"

  python3 - "$file" "$target" <<'PY'
import json, sys

file_path = sys.argv[1]
target = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

lists = []
if isinstance(data, list):
    lists.append(data)
if isinstance(data, dict):
    for key in ("products", "items", "data"):
        value = data.get(key)
        if isinstance(value, list):
            lists.append(value)
        elif isinstance(value, dict):
            for k2 in ("products", "items", "data"):
                if isinstance(value.get(k2), list):
                    lists.append(value[k2])

for arr in lists:
    for p in arr:
        if isinstance(p, dict) and p.get("name") == target:
            print(p.get("id") or p.get("ID") or "")
            sys.exit(0)

print("")
PY
}

json_find_cart_quantity_by_product_id() {
  local file="$1"
  local product_id="$2"

  python3 - "$file" "$product_id" <<'PY'
import json, sys

file_path = sys.argv[1]
product_id = str(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0")
    sys.exit(0)

candidates = []

def collect(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("items"), list):
            candidates.extend(obj["items"])
        if isinstance(obj.get("cart"), dict):
            collect(obj["cart"])
        if isinstance(obj.get("data"), dict):
            collect(obj["data"])
    elif isinstance(obj, list):
        candidates.extend(obj)

collect(data)

for item in candidates:
    if not isinstance(item, dict):
        continue
    pid = item.get("product_id")
    if pid is None:
        pid = item.get("ProductID")
    if str(pid) == product_id:
        qty = item.get("quantity")
        if qty is None:
            qty = item.get("Quantity")
        print(qty if qty is not None else "0")
        sys.exit(0)

print("0")
PY
}

new_uuid() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

req() {
  local label="$1"
  local method="$2"
  local url="$3"
  local payload="${4:-}"
  shift 4 || true

  local headers="$HTTP_DIR/$label.headers"
  local body="$HTTP_DIR/$label.json"
  local code_file="$HTTP_DIR/$label.code"
  local req_file="$HTTP_DIR/$label.request.txt"

  {
    echo "$method $url"
    for h in "$@"; do
      case "$h" in
        Authorization:*) echo "Authorization: Bearer ***" ;;
        X-Internal-Service-Token:*) echo "X-Internal-Service-Token: ***" ;;
        *) echo "$h" ;;
      esac
    done
    [[ -n "$payload" ]] && echo "BODY: $payload"
  } > "$req_file"

  local args=(curl -sS -X "$method" "$url" -D "$headers" -o "$body" -w '%{http_code}' -H "Accept: application/json")

  if [[ -n "$payload" ]]; then
    args+=(-H "Content-Type: application/json" --data "$payload")
  fi

  local h
  for h in "$@"; do
    [[ -n "$h" ]] && args+=(-H "$h")
  done

  local code
  code="$("${args[@]}" 2>/dev/null || printf "000")"
  printf '%s' "$code" > "$code_file"
  printf '%s' "$code"
}

is_2xx() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }
is_4xx() { [[ "$1" =~ ^4[0-9][0-9]$ ]]; }
is_401_403() { [[ "$1" == "401" || "$1" == "403" ]]; }
auth_h() { printf "Authorization: Bearer %s" "$1"; }
internal_h() { printf "X-Internal-Service-Token: %s" "$INTERNAL_SERVICE_TOKEN"; }
cart_internal_h() { printf "X-Internal-Service-Token: %s" "$CART_INTERNAL_SERVICE_TOKEN"; }

wait_ready_one() {
  local label="$1"
  local url="$2"
  local max="${3:-60}"
  local i code body

  for ((i=1; i<=max; i++)); do
    code="$(req "wait-$label-$i" GET "$url/readyz")"

    if is_2xx "$code"; then
      record PASS "ready $label" "HTTP $code after attempt $i/$max"
      return 0
    fi

    body="$(body_flat "$HTTP_DIR/wait-$label-$i.json")"
    yellow "WAIT - ready $label - attempt $i/$max HTTP $code ${body:0:160}"
    sleep 5
  done

  record FAIL "ready $label" "last HTTP $code body=$(body_flat "$HTTP_DIR/wait-$label-$max.json")"
  return 1
}

wake_services() {
  blue "== Wake services / readiness =="

  wait_ready_one auth "$AUTH_BASE"
  wait_ready_one user "$USER_BASE"
  wait_ready_one catalog "$CATALOG_BASE"
  wait_ready_one cart "$CART_BASE"
  wait_ready_one order "$ORDER_BASE"
  wait_ready_one payment "$PAYMENT_BASE"
  wait_ready_one gateway "$API_BASE"

  req "warmup-gateway-livez" GET "$API_BASE/livez" >/dev/null
  req "warmup-catalog-products" GET "$API_BASE/catalog/products?page=1&page_size=1" >/dev/null
  req "warmup-cart-auth-check" GET "$API_BASE/cart/" >/dev/null
  req "warmup-cart-readyz" GET "$CART_BASE/readyz" >/dev/null
  req "warmup-payment-readyz" GET "$PAYMENT_BASE/readyz" >/dev/null

  sleep 2
}

register_user() {
  local label="$1"

  USER_SEQ=$((USER_SEQ+1))

  local suffix="${RUN_ID: -6}${USER_SEQ}"
  local username="u${suffix}"
  local email="${username}@test.local"
  local full_name="E2E ${username}"

  local payload
  payload="$(cat <<JSON
{
  "email": "$email",
  "password": "$PASSWORD",
  "username": "$username",
  "full_name": "$full_name",
  "role": "buyer"
}
JSON
)"

  local code
  code="$(req "auth-register-$label" POST "$API_BASE/auth/register" "$payload")"

  local token user_id
  token="$(json_get "$HTTP_DIR/auth-register-$label.json" ".access_token")"

  user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".user_id")"
  [[ -z "$user_id" ]] && user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".id")"
  [[ -z "$user_id" ]] && user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".user.id")"
  [[ -z "$user_id" && -n "$token" ]] && user_id="$(token_user_id "$token")"

  if is_2xx "$code" && [[ -n "$token" && -n "$user_id" ]]; then
    record PASS "register $label" "email=$email user_id=$user_id"
    state_put "${label}_email" "$email"
    state_put "${label}_username" "$username"
    state_put "${label}_token" "$token"
    state_put "${label}_id" "$user_id"
    return 0
  fi

  record FAIL "register $label" "HTTP $code token_present=$([[ -n "$token" ]] && echo yes || echo no) user_id=${user_id:-missing} body=$(body_flat "$HTTP_DIR/auth-register-$label.json")"
  return 1
}

auth_suite() {
  blue "== Auth setup =="

  register_user seller_direct
  register_user buyer_direct
  register_user seller_checkout
  register_user buyer_checkout
}

create_product() {
  local label="$1"
  local token="$2"
  local price="$3"
  local stock="$4"

  local payload
  payload="$(cat <<JSON
{
  "name": "$label",
  "description": "E2E SDD7 product $label",
  "price": $price,
  "stock_quantity": $stock,
  "image_bucket_url": "",
  "category": "technology",
  "status": "active"
}
JSON
)"

  local code
  code="$(req "catalog-create-$label" POST "$API_BASE/catalog/me/products" "$payload" "$(auth_h "$token")" "Idempotency-Key: product-$label-$RUN_ID")"

  if is_2xx "$code"; then
    record PASS "create product $label" "HTTP $code"
    return 0
  fi

  record FAIL "create product $label" "HTTP $code body=$(body_flat "$HTTP_DIR/catalog-create-$label.json")"
  return 1
}

list_my_products() {
  local label="$1"
  local token="$2"
  req "catalog-list-mine-$label" GET "$API_BASE/catalog/me/products?page=1&page_size=100" "" "$(auth_h "$token")" >/dev/null
}

catalog_setup_suite() {
  blue "== Catalog setup =="

  local seller_direct seller_checkout
  seller_direct="$(state_get seller_direct_token)"
  seller_checkout="$(state_get seller_checkout_token)"

  create_product "SDD7_DIRECT_PARTIAL_${RUN_ID}" "$seller_direct" 100 20
  create_product "SDD7_DIRECT_FULL_${RUN_ID}" "$seller_direct" 120 20
  create_product "SDD7_CHECKOUT_${RUN_ID}" "$seller_checkout" 150 20

  list_my_products seller_direct "$seller_direct"
  list_my_products seller_checkout "$seller_checkout"

  local p

  p="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_direct.json" "SDD7_DIRECT_PARTIAL_${RUN_ID}")"
  state_put SDD7_DIRECT_PARTIAL_ID "$p"
  [[ -n "$p" ]] && record PASS "find SDD7_DIRECT_PARTIAL id" "id=$p" || record FAIL "find SDD7_DIRECT_PARTIAL id" "missing"

  p="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_direct.json" "SDD7_DIRECT_FULL_${RUN_ID}")"
  state_put SDD7_DIRECT_FULL_ID "$p"
  [[ -n "$p" ]] && record PASS "find SDD7_DIRECT_FULL id" "id=$p" || record FAIL "find SDD7_DIRECT_FULL id" "missing"

  p="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_checkout.json" "SDD7_CHECKOUT_${RUN_ID}")"
  state_put SDD7_CHECKOUT_ID "$p"
  [[ -n "$p" ]] && record PASS "find SDD7_CHECKOUT id" "id=$p" || record FAIL "find SDD7_CHECKOUT id" "missing"
}

add_to_cart() {
  local label="$1"
  local token="$2"
  local product_id="$3"
  local qty="$4"

  local payload="{\"product_id\":$product_id,\"quantity\":$qty}"
  local code
  code="$(req "cart-add-$label" POST "$API_BASE/cart/items" "$payload" "$(auth_h "$token")")"

  if is_2xx "$code"; then
    record PASS "cart add $label" "product=$product_id qty=$qty"
    return 0
  fi

  record FAIL "cart add $label" "HTTP $code product=$product_id qty=$qty body=$(body_flat "$HTTP_DIR/cart-add-$label.json")"
  return 1
}

get_cart() {
  local label="$1"
  local token="$2"
  req "cart-get-$label" GET "$API_BASE/cart/" "" "$(auth_h "$token")"
}

cart_qty() {
  local label="$1"
  local product_id="$2"
  json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-$label.json" "$product_id"
}

internal_cart_cleanup() {
  local label="$1"
  local buyer_id="$2"
  local checkout_group_id="$3"
  local items_json="$4"

  local payload
  payload="$(cat <<JSON
{
  "buyer_id": $buyer_id,
  "checkout_group_id": "$checkout_group_id",
  "items": $items_json
}
JSON
)"

  req "cart-cleanup-$label" POST "$CART_BASE/internal/checkout-cleanup" "$payload" "$(cart_internal_h)"
}

cart_internal_cleanup_suite() {
  blue "== SDD7 direct cart-service internal cleanup =="

  local buyer buyer_id partial full code cgid qty
  buyer="$(state_get buyer_direct_token)"
  buyer_id="$(state_get buyer_direct_id)"
  partial="$(state_get SDD7_DIRECT_PARTIAL_ID)"
  full="$(state_get SDD7_DIRECT_FULL_ID)"

  # Preflight: if this fails with 401, the rest of SDD7 direct cleanup assertions
  # would be meaningless. It usually means CART_INTERNAL_SERVICE_TOKEN does not
  # match cart-service INTERNAL_SERVICE_TOKEN in Render.
  code="$(req cart-cleanup-token-preflight POST "$CART_BASE/internal/checkout-cleanup" "{\"buyer_id\":999999999,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":1,\"quantity\":1}]}" "$(cart_internal_h)")"
  if ! is_2xx "$code"; then
    record FAIL "cart cleanup internal token preflight" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-token-preflight.json")"
    record SKIP "cart cleanup direct SDD7 assertions" "Fix CART_INTERNAL_SERVICE_TOKEN / cart-service INTERNAL_SERVICE_TOKEN first"
    return 0
  fi
  record PASS "cart cleanup internal token preflight" "HTTP $code"

  local valid_payload
  valid_payload="{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":$partial,\"quantity\":1}]}"

  code="$(req cart-cleanup-no-token POST "$CART_BASE/internal/checkout-cleanup" "$valid_payload")"
  is_4xx "$code" && record PASS "cart cleanup no token" "HTTP $code" || record FAIL "cart cleanup no token" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-no-token.json")"

  code="$(req cart-cleanup-bad-token POST "$CART_BASE/internal/checkout-cleanup" "$valid_payload" "X-Internal-Service-Token: wrong-token")"
  is_4xx "$code" && record PASS "cart cleanup bad token" "HTTP $code" || record FAIL "cart cleanup bad token" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-bad-token.json")"

  code="$(req cart-cleanup-missing-cg POST "$CART_BASE/internal/checkout-cleanup" "{\"buyer_id\":$buyer_id,\"items\":[{\"product_id\":$partial,\"quantity\":1}]}" "$(cart_internal_h)")"
  is_4xx "$code" && record PASS "cart cleanup missing checkout_group_id" "HTTP $code" || record FAIL "cart cleanup missing checkout_group_id" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-missing-cg.json")"

  code="$(req cart-cleanup-empty-items POST "$CART_BASE/internal/checkout-cleanup" "{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[]}" "$(cart_internal_h)")"
  is_4xx "$code" && record PASS "cart cleanup empty items" "HTTP $code" || record FAIL "cart cleanup empty items" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-empty-items.json")"

  code="$(req cart-cleanup-zero-qty POST "$CART_BASE/internal/checkout-cleanup" "{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":$partial,\"quantity\":0}]}" "$(cart_internal_h)")"
  is_4xx "$code" && record PASS "cart cleanup zero quantity" "HTTP $code" || record FAIL "cart cleanup zero quantity" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-zero-qty.json")"

  add_to_cart direct-partial-initial "$buyer" "$partial" 4
  get_cart direct-partial-before "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-before "$partial")"
  [[ "$qty" == "4" ]] && record PASS "cart setup partial quantity" "qty=$qty" || record FAIL "cart setup partial quantity" "qty=$qty expected=4"

  cgid="$(new_uuid)"
  code="$(internal_cart_cleanup direct-partial "$buyer_id" "$cgid" "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup partial direct" "HTTP $code cg=$cgid" || record FAIL "cart cleanup partial direct" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial.json")"

  get_cart direct-partial-after "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-after "$partial")"
  [[ "$qty" == "2" ]] && record PASS "cart cleanup partial decrements" "qty=$qty" || record FAIL "cart cleanup partial decrements" "qty=$qty expected=2"

  code="$(internal_cart_cleanup direct-partial-retry "$buyer_id" "$cgid" "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup partial retry HTTP" "HTTP $code" || record FAIL "cart cleanup partial retry HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial-retry.json")"

  get_cart direct-partial-retry-after "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-retry-after "$partial")"
  [[ "$qty" == "2" ]] && record PASS "cart cleanup retry idempotent" "qty=$qty" || record FAIL "cart cleanup retry idempotent" "qty=$qty expected=2"

  add_to_cart direct-partial-readd "$buyer" "$partial" 3
  get_cart direct-partial-readd-before-retry "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-readd-before-retry "$partial")"
  [[ "$qty" == "5" ]] && record PASS "cart re-add after cleanup" "qty=$qty" || record FAIL "cart re-add after cleanup" "qty=$qty expected=5"

  code="$(internal_cart_cleanup direct-partial-retry-after-readd "$buyer_id" "$cgid" "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup retry after re-add HTTP" "HTTP $code" || record FAIL "cart cleanup retry after re-add HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial-retry-after-readd.json")"

  get_cart direct-partial-after-readd-retry "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-after-readd-retry "$partial")"
  [[ "$qty" == "5" ]] && record PASS "cart cleanup does not delete re-added items" "qty=$qty" || record FAIL "cart cleanup does not delete re-added items" "qty=$qty expected=5"

  add_to_cart direct-full-initial "$buyer" "$full" 2
  get_cart direct-full-before "$buyer" >/dev/null
  qty="$(cart_qty direct-full-before "$full")"
  [[ "$qty" == "2" ]] && record PASS "cart setup full quantity" "qty=$qty" || record FAIL "cart setup full quantity" "qty=$qty expected=2"

  cgid="$(new_uuid)"
  code="$(internal_cart_cleanup direct-full "$buyer_id" "$cgid" "[{\"product_id\":$full,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup full direct" "HTTP $code cg=$cgid" || record FAIL "cart cleanup full direct" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-full.json")"

  get_cart direct-full-after "$buyer" >/dev/null
  qty="$(cart_qty direct-full-after "$full")"
  [[ "$qty" == "0" ]] && record PASS "cart cleanup full removes item" "qty=$qty" || record FAIL "cart cleanup full removes item" "qty=$qty expected=0"

  add_to_cart direct-full-readd "$buyer" "$full" 1
  get_cart direct-full-readd-after "$buyer" >/dev/null
  qty="$(cart_qty direct-full-readd-after "$full")"
  [[ "$qty" == "1" ]] && record PASS "cart hard-delete allows re-add" "qty=$qty" || record FAIL "cart hard-delete allows re-add" "qty=$qty expected=1"
}

checkout() {
  local label="$1"
  local token="$2"
  local idem="$3"
  local payload='{"delivery_address":"Av E2E 123","delivery_city":"CABA","delivery_province":"Buenos Aires"}'
  req "checkout-$label" POST "$API_BASE/checkout" "$payload" "$(auth_h "$token")" "Idempotency-Key: $idem"
}

order_id_first() {
  local label="$1"
  local file="$HTTP_DIR/checkout-$label.json"
  local oid
  oid="$(json_get "$file" ".orders[0].order_id")"
  [[ -z "$oid" ]] && oid="$(json_get "$file" ".order_id")"
  printf '%s' "$oid"
}

checkout_sdd7_cleanup_suite() {
  blue "== SDD7 order-service integrated cleanup after approved checkout =="

  local buyer product code cgid status order_status order_id qty idem
  buyer="$(state_get buyer_checkout_token)"
  product="$(state_get SDD7_CHECKOUT_ID)"
  idem="sdd7-checkout-approved-cleanup-$RUN_ID"

  add_to_cart checkout-cleanup-initial "$buyer" "$product" 2

  get_cart checkout-cleanup-before "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-before "$product")"
  [[ "$qty" == "2" ]] && record PASS "checkout cleanup setup cart quantity" "qty=$qty" || record FAIL "checkout cleanup setup cart quantity" "qty=$qty expected=2"

  code="$(checkout sdd7-approved "$buyer" "$idem")"
  cgid="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".checkout_group_id")"
  status="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".status")"
  order_status="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".orders[0].status")"
  order_id="$(order_id_first sdd7-approved)"
  state_put SDD7_CHECKOUT_GROUP_ID "$cgid"
  state_put SDD7_CHECKOUT_ORDER_ID "$order_id"

  if is_2xx "$code" && [[ -n "$cgid" && "$status $order_status" == *"confirm"* ]]; then
    record PASS "checkout approved before cleanup assertion" "cg=$cgid order=$order_id status=$status order_status=$order_status"
  else
    record FAIL "checkout approved before cleanup assertion" "HTTP $code cg=$cgid status=$status order_status=$order_status body=$(body_flat "$HTTP_DIR/checkout-sdd7-approved.json")"
  fi

  get_cart checkout-cleanup-after "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-after "$product")"
  [[ "$qty" == "0" ]] && record PASS "order-service cleanup removed purchased item" "qty=$qty" || record FAIL "order-service cleanup removed purchased item" "qty=$qty expected=0"

  add_to_cart checkout-cleanup-readd "$buyer" "$product" 3
  get_cart checkout-cleanup-readd-before-retry "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-readd-before-retry "$product")"
  [[ "$qty" == "3" ]] && record PASS "buyer can re-add after confirmed checkout cleanup" "qty=$qty" || record FAIL "buyer can re-add after confirmed checkout cleanup" "qty=$qty expected=3"

  code="$(checkout sdd7-approved-retry-after-readd "$buyer" "$idem")"
  if is_2xx "$code"; then
    record PASS "checkout retry after re-add HTTP" "HTTP $code"
  else
    record FAIL "checkout retry after re-add HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-sdd7-approved-retry-after-readd.json")"
  fi

  get_cart checkout-cleanup-after-retry "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-after-retry "$product")"
  [[ "$qty" == "3" ]] && record PASS "checkout retry does not cleanup re-added items" "qty=$qty" || record FAIL "checkout retry does not cleanup re-added items" "qty=$qty expected=3"
}


admin_login() {
  local payload code token

  payload="$(cat <<JSON
{
  "email": "$ADMIN_EMAIL",
  "password": "$ADMIN_PASSWORD"
}
JSON
)"

  code="$(req admin-login POST "$API_BASE/auth/login" "$payload")"
  token="$(json_get "$HTTP_DIR/admin-login.json" ".access_token")"

  if is_2xx "$code" && [[ -n "$token" ]]; then
    record PASS "admin login" "email=$ADMIN_EMAIL"
    state_put admin_token "$token"
    return 0
  fi

  record FAIL "admin login" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-login.json")"
  return 1
}

admin_smoke_suite() {
  blue "== Admin endpoints smoke =="

  local admin buyer order_id code

  if ! admin_login; then
    record SKIP "admin smoke suite" "admin login failed"
    return 0
  fi

  admin="$(state_get admin_token)"
  buyer="$(state_get buyer_checkout_token)"
  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"

  code="$(req admin-users-list-admin GET "$API_BASE/admin/users/" "" "$(auth_h "$admin")")"
  if is_2xx "$code"; then
    record PASS "admin users list with admin" "HTTP $code"
  else
    record FAIL "admin users list with admin" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-users-list-admin.json")"
  fi

  code="$(req admin-users-list-buyer GET "$API_BASE/admin/users/" "" "$(auth_h "$buyer")")"
  if is_401_403 "$code"; then
    record PASS "admin users list forbidden for buyer" "HTTP $code"
  else
    record FAIL "admin users list forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-users-list-buyer.json")"
  fi

  code="$(req admin-orders-list-admin GET "$API_BASE/admin/orders/" "" "$(auth_h "$admin")")"
  if is_2xx "$code"; then
    record PASS "admin orders list with admin" "HTTP $code"
  else
    record FAIL "admin orders list with admin" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-orders-list-admin.json")"
  fi

  code="$(req admin-orders-list-buyer GET "$API_BASE/admin/orders/" "" "$(auth_h "$buyer")")"
  if is_401_403 "$code"; then
    record PASS "admin orders list forbidden for buyer" "HTTP $code"
  else
    record FAIL "admin orders list forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-orders-list-buyer.json")"
  fi

  if [[ -n "$order_id" ]]; then
    code="$(req admin-order-detail-admin GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin order detail with admin" "HTTP $code order=$order_id"
    else
      record FAIL "admin order detail with admin" "HTTP $code order=$order_id body=$(body_flat "$HTTP_DIR/admin-order-detail-admin.json")"
    fi

    code="$(req admin-order-detail-buyer GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$buyer")")"
    if is_401_403 "$code"; then
      record PASS "admin order detail forbidden for buyer" "HTTP $code"
    else
      record FAIL "admin order detail forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-detail-buyer.json")"
    fi
  else
    record SKIP "admin order detail" "SDD7_CHECKOUT_ORDER_ID missing"
  fi
}


write_report() {
  {
    echo "# Bazaar Render E2E Checkout Saga SDD7"
    echo ""
    echo "- RUN_ID: $RUN_ID"
    echo "- API_BASE: $API_BASE"
    echo "- CART_BASE: $CART_BASE"
    echo "- ORDER_BASE: $ORDER_BASE"
    echo "- PAYMENT_BASE: $PAYMENT_BASE"
    echo "- OUT_DIR: $OUT_DIR"
    echo ""
    echo "## Results"
    echo ""
    echo "| Estado | Caso | Notas |"
    echo "|---|---|---|"
    while IFS=$'\t' read -r status name note; do
      echo "| $status | $name | $note |"
    done < "$RESULTS"
    echo ""
    echo "## Summary"
    echo ""
    echo "- PASS: $PASS"
    echo "- FAIL: $FAIL"
    echo "- SKIP: $SKIP"
    echo ""
    echo "## Raw"
    echo ""
    echo "$HTTP_DIR"
  } > "$REPORT"
}

main() {
  blue "RUN_ID=$RUN_ID"
  blue "OUT_DIR=$OUT_DIR"
  blue "INTERNAL_TOKEN_LEN=${#INTERNAL_SERVICE_TOKEN}"
  blue "CART_INTERNAL_TOKEN_LEN=${#CART_INTERNAL_SERVICE_TOKEN}"
  blue "PAYMENT_SIMULATION_MODE expected: approved"

  wake_services
  auth_suite
  catalog_setup_suite
  cart_internal_cleanup_suite
  checkout_sdd7_cleanup_suite
  admin_smoke_suite

  write_report

  blue "== Summary =="
  echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  echo "REPORT=$REPORT"
  echo "RAW=$HTTP_DIR"

  if (( FAIL > 0 )); then
    red "E2E SDD7 finished with failures."
    exit 1
  fi

  green "E2E SDD7 finished without blocking failures."
}

main "$@"

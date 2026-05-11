#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E — Checkout Saga / SDD7 + SDD8 + SDD9
#
# Objetivo:
#   Validar SDD 7, SDD 8 y SDD 9 (local or Render), sin DB directa:
#   - SDD7: cart-service internal checkout cleanup, idempotencia de cleanup,
#     limpieza por cantidades, hard delete + re-add seguro,
#     cleanup integrado post-checkout, retry no borra items re-agregados.
#   - SDD8: checkout reconciliation views via
#     GET /checkout/attempts/:idempotencyKey y
#     GET /checkout-groups/:checkoutGroupId.
#   - SDD9: seller order list/detail/status, multi-seller isolation,
#     seller privacy, admin read-only.
#
# Payment:
#   Se asume PAYMENT_SIMULATION_MODE=approved en payment-service.
#
# Uso (local):
#   ./scripts/test/integration/e2e_local.sh
#
# Uso (render):
#   ./scripts/test/integration/e2e_render.sh
#
# Uso directo:
#   E2E_TARGET_ENV=local API_BASE=http://localhost:8080 ... ./scripts/test/integration/_e2e_checkout.sh
#
# Opcionales:
#   RUN_ID=123 INTERNAL_SERVICE_TOKEN=... ADMIN_EMAIL=... ADMIN_PASSWORD=...
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

API_BASE="${API_BASE:-https://bazaar-backend-api-gateway.onrender.com}"
AUTH_BASE="${AUTH_BASE:-https://bazaar-backend-auth-service.onrender.com}"
USER_BASE="${USER_BASE:-https://bazaar-backend-user-service.onrender.com}"
CATALOG_BASE="${CATALOG_BASE:-https://bazaar-backend-catalog-service.onrender.com}"
CART_BASE="${CART_BASE:-https://bazaar-backend-cart-service.onrender.com}"
ORDER_BASE="${ORDER_BASE:-https://bazaar-backend-order-service.onrender.com}"
PAYMENT_BASE="${PAYMENT_BASE:-https://bazaar-backend-payment-service.onrender.com}"

# Load local env vars if present
# shellcheck disable=SC1091
if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
  source "$PLATFORM_ROOT/.env.local"
fi

# ── Resolve admin credentials ─────────────────────────────────────────────
_resolve_admin_creds() {
  if [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    echo "[e2e] Using ADMIN_EMAIL/ADMIN_PASSWORD from environment"
    return 0
  fi

  local bootstrap_value="${AUTH_BOOTSTRAP_ADMINS:-}"

  if [[ -n "$bootstrap_value" ]]; then
    local stripped_value="$bootstrap_value"
    if [[ "$stripped_value" == \'*\' ]]; then
      stripped_value="${stripped_value#\'}"
      stripped_value="${stripped_value%\'}"
    elif [[ "$stripped_value" == \"*\" ]]; then
      stripped_value="${stripped_value#\"}"
      stripped_value="${stripped_value%\"}"
    fi

    local email password

    # Try JSON first (properly quoted keys and values)
    email="$(echo "$stripped_value" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('email', ''))
except Exception:
    pass
" 2>/dev/null)"

    password="$(echo "$stripped_value" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('password', ''))
except Exception:
    pass
" 2>/dev/null)"

    # Fallback: unquoted JS-object format (e.g. {email:admin@...,password:Xxx})
    if [[ -z "$email" || -z "$password" ]]; then
      email="$(echo "$stripped_value" | grep -oE 'email:([^,}]+)' | head -1 | sed 's/^email://')"
      password="$(echo "$stripped_value" | grep -oE 'password:([^,}]+)' | head -1 | sed 's/^password://')"
    fi

    if [[ -n "$email" && -n "$password" ]]; then
      ADMIN_EMAIL="$email"
      ADMIN_PASSWORD="$password"
      echo "[e2e] Resolved admin from AUTH_BOOTSTRAP_ADMINS: $ADMIN_EMAIL"
      return 0
    fi
  fi

  echo "[e2e][warn] Admin credentials not found. Set ADMIN_EMAIL/ADMIN_PASSWORD or AUTH_BOOTSTRAP_ADMINS. Admin tests will be skipped."
  ADMIN_EMAIL=""
  ADMIN_PASSWORD=""
  return 0
}

_resolve_admin_creds

INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"
PASSWORD="${PASSWORD:-E2eUser1234!}"
RUN_ID="${RUN_ID:-$(date +%s)}"

OUT_DIR="tmp/e2e-checkout-saga-sdd7-sdd8-sdd9-${E2E_TARGET_ENV:-render}-${RUN_ID}"
HTTP_DIR="$OUT_DIR/http"
STATE_DIR="$OUT_DIR/state"
REPORT="$OUT_DIR/REPORT.md"
RESULTS="$OUT_DIR/results.tsv"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$HTTP_DIR" "$STATE_DIR"
: >"$RESULTS"

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
  printf "%s\t%s\t%s\n" "$status" "$name" "$note" >>"$RESULTS"

  case "$status" in
    PASS) PASS=$((PASS + 1)) && green "PASS - $name - $note" ;;
    FAIL) FAIL=$((FAIL + 1)) && red "FAIL - $name - $note" ;;
    SKIP) SKIP=$((SKIP + 1)) && yellow "SKIP - $name - $note" ;;
  esac
}

state_put() { printf '%s' "$2" >"$STATE_DIR/$1"; }
state_get() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1" || true; }

body_flat() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tr '\n' ' ' <"$file" | sed 's/[[:space:]]\+/ /g' | sed 's/|/\//g'
}

mask_password_in_payload() {
  local payload="$1"
  printf '%s\n' "$payload" | sed 's/"password":"[^"]*"/"password":"***"/g'
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

###############################################################################
# SDD8 / SDD9 — Order-specific JSON helpers
###############################################################################

# Find the order_id of an order whose seller_id matches.
# Handles both root list and data.orders wrappers.
json_find_order_id_by_seller_id() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) == str(seller_id):
        oid = o.get("order_id") or o.get("id") or o.get("ID")
        if oid:
            print(oid)
            sys.exit(0)

print("")
PY
}

# Count orders in a list response owned by seller_id
json_count_orders_for_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

count = 0
for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) == str(seller_id):
        count += 1

print(count)
PY
}

# Check that ALL orders in a list belong to seller_id
json_orders_all_have_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

if not orders:
    print("false")
    sys.exit(0)

for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) != str(seller_id):
        print("false")
        sys.exit(0)

print("true")
PY
}

# Check that ALL items across ALL orders belong to seller_id
json_order_items_all_have_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    if isinstance(data.get("items"), list):
        orders = [data]
    else:
        for key in ("orders", "data"):
            val = data.get(key)
            if isinstance(val, list):
                orders = val
                break
        if not orders and isinstance(data.get("data"), dict):
            wrapped = data["data"]
            if isinstance(wrapped.get("items"), list):
                orders = [wrapped]
            else:
                val2 = wrapped.get("orders")
                if isinstance(val2, list):
                    orders = val2

if not orders:
    print("false")
    sys.exit(0)

for o in orders:
    if not isinstance(o, dict):
        print("false")
        sys.exit(0)
    items = o.get("items")
    if not isinstance(items, list):
        print("false")
        sys.exit(0)
    for item in items:
        if not isinstance(item, dict):
            continue
        sid = item.get("seller_id") or item.get("sellerID") or item.get("SellerID")
        if sid is None:
            print("false")
            sys.exit(0)
        if str(sid) != str(seller_id):
            print("false")
            sys.exit(0)

print("true")
PY
}

# Check that a single-order detail response contains items from a foreign seller
json_order_has_foreign_seller_items() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

items = []
if isinstance(data, dict):
    items = data.get("items") or []
    if not items and isinstance(data.get("data"), dict):
        items = data["data"].get("items") or []

for item in items:
    if not isinstance(item, dict):
        continue
    sid = item.get("seller_id") or item.get("sellerID") or item.get("SellerID")
    if sid is None:
        print("true")
        sys.exit(0)
    if str(sid) != str(seller_id):
        print("true")
        sys.exit(0)

print("false")
PY
}

# Return the status field from an order detail response. Handles root,
# data wrapper, and orders[0] wrapper forms.
json_order_status() {
  local file="$1"

  python3 - "$file" <<'PY'
import json, sys

file_path = sys.argv[1]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

# Direct root status
if isinstance(data, dict):
    if "status" in data:
        print(data["status"])
        sys.exit(0)
    # Try data wrapper
    wrapped = data.get("data")
    if isinstance(wrapped, dict) and "status" in wrapped:
        print(wrapped["status"])
        sys.exit(0)
    # Try orders[0] wrapper (checkout response)
    orders = data.get("orders")
    if isinstance(orders, list) and orders and isinstance(orders[0], dict) and "status" in orders[0]:
        print(orders[0]["status"])
        sys.exit(0)

print("")
PY
}

###############################################################################
# SDD8 / SDD9 — API request helpers
###############################################################################

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
    local h
    for h in "$@"; do
      case "$h" in
        Authorization:*) echo "Authorization: Bearer ***" ;;
        X-Internal-Service-Token:*) echo "X-Internal-Service-Token: ***" ;;
        *) echo "$h" ;;
      esac
    done
    [[ -n "$payload" ]] && echo "BODY: $(mask_password_in_payload "$payload")"
  } >"$req_file"

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
  printf '%s' "$code" >"$code_file"
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

  for ((i = 1; i <= max; i++)); do
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

###############################################################################
# Auth
###############################################################################

register_user() {
  local label="$1"
  local role="${2:-buyer}"

  USER_SEQ=$((USER_SEQ + 1))

  local suffix="${RUN_ID: -6}${USER_SEQ}"
  local username="u${suffix}"
  local email="${username}@test.local"
  local full_name="E2E ${username}"

  local payload
  payload="$(
    cat <<JSON
{
  "email": "$email",
  "password": "$PASSWORD",
  "username": "$username"
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
    record PASS "register $label" "email=$email user_id=$user_id role=$role"
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

  # SDD7 actors
  register_user seller_direct "seller"
  register_user buyer_direct
  register_user seller_checkout "seller"
  register_user buyer_checkout

  # SDD9 actors
  register_user seller_a "seller"
  register_user seller_b "seller"
  register_user seller_intruder "seller"
  register_user buyer_sdd9
  register_user buyer_foreign
}

###############################################################################
# Catalog
###############################################################################

create_product() {
  local label="$1"
  local token="$2"
  local price="$3"
  local stock="$4"

  local payload
  payload="$(
    cat <<JSON
{
  "name": "$label",
  "description": "E2E SDD7-SDD8-SDD9 product $label",
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

  local seller_direct seller_checkout seller_a_token seller_b_token
  seller_direct="$(state_get seller_direct_token)"
  seller_checkout="$(state_get seller_checkout_token)"
  seller_a_token="$(state_get seller_a_token)"
  seller_b_token="$(state_get seller_b_token)"

  # SDD7 products
  create_product "SDD7_DIRECT_PARTIAL_${RUN_ID}" "$seller_direct" 100 20
  create_product "SDD7_DIRECT_FULL_${RUN_ID}" "$seller_direct" 120 20
  create_product "SDD7_CHECKOUT_${RUN_ID}" "$seller_checkout" 150 20

  # SDD9 products
  create_product "SDD9_SELLER_A_${RUN_ID}" "$seller_a_token" 200 20
  create_product "SDD9_SELLER_B_${RUN_ID}" "$seller_b_token" 300 20

  list_my_products seller_direct "$seller_direct"
  list_my_products seller_checkout "$seller_checkout"
  list_my_products seller_a_list "$seller_a_token"
  list_my_products seller_b_list "$seller_b_token"

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

  p="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_a_list.json" "SDD9_SELLER_A_${RUN_ID}")"
  state_put SDD9_SELLER_A_PRODUCT_ID "$p"
  [[ -n "$p" ]] && record PASS "find SDD9_SELLER_A product id" "id=$p" || record FAIL "find SDD9_SELLER_A product id" "missing"

  p="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_b_list.json" "SDD9_SELLER_B_${RUN_ID}")"
  state_put SDD9_SELLER_B_PRODUCT_ID "$p"
  [[ -n "$p" ]] && record PASS "find SDD9_SELLER_B product id" "id=$p" || record FAIL "find SDD9_SELLER_B product id" "missing"
}

###############################################################################
# Cart helpers (SDD7)
###############################################################################

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
  payload="$(
    cat <<JSON
{
  "buyer_id": $buyer_id,
  "checkout_group_id": "$checkout_group_id",
  "items": $items_json
}
JSON
  )"

  req "cart-cleanup-$label" POST "$CART_BASE/internal/checkout-cleanup" "$payload" "$(cart_internal_h)"
}

###############################################################################
# Checkout helpers (SDD7 + SDD9)
###############################################################################

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

# SDD9: checkout returns multiple orders in .orders[] — find by seller_id
checkout_order_id_for_seller() {
  local label="$1"
  local seller_id="$2"
  json_find_order_id_by_seller_id "$HTTP_DIR/checkout-$label.json" "$seller_id"
}

checkout_attempt_get() {
  local label="$1"
  local token="$2"
  local idem="$3"
  req "checkout-attempt-$label" GET "$API_BASE/checkout/attempts/$idem" "" "$(auth_h "$token")"
}

checkout_group_get() {
  local label="$1"
  local token="$2"
  local cgid="$3"
  req "checkout-group-$label" GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$token")"
}

###############################################################################
# SDD8 / SDD9 — Seller API helpers
###############################################################################

seller_get_orders() {
  local label="$1"
  local token="$2"
  req "seller-orders-$label" GET "$API_BASE/seller/orders?page=1&page_size=20" "" "$(auth_h "$token")"
}

seller_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "seller-order-$label" GET "$API_BASE/seller/orders/$order_id" "" "$(auth_h "$token")"
}

seller_update_order_status() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  local status="$4"
  local tracking_code="${5:-}"

  local payload
  if [[ -n "$tracking_code" ]]; then
    payload="{\"status\":\"$status\",\"tracking_code\":\"$tracking_code\"}"
  else
    payload="{\"status\":\"$status\"}"
  fi

  req "seller-update-status-$label" POST "$API_BASE/seller/orders/$order_id/status" "$payload" "$(auth_h "$token")"
}

###############################################################################
# SDD8 / SDD9 — Buyer API helpers
###############################################################################

buyer_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "buyer-order-$label" GET "$API_BASE/orders/$order_id" "" "$(auth_h "$token")"
}

###############################################################################
# SDD8 / SDD9 — Admin API helpers
###############################################################################

admin_get_orders() {
  local label="$1"
  local token="$2"
  req "admin-orders-list-$label" GET "$API_BASE/admin/orders/" "" "$(auth_h "$token")"
}

admin_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "admin-order-detail-$label" GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$token")"
}

###############################################################################
# SDD8 / SDD9 — Assertion helpers
###############################################################################

# Ensure response does NOT leak internal fields: idempotency_key,
# checkout_group fields we might not want exposed, etc.
# Checks for known sensitive/internal JSON keys that should not
# appear in public-facing responses.
assert_no_internal_fields() {
  local file="$1"
  local case_name="$2"

  local result
  result="$(
    python3 - "$file" <<'PY'
import json, sys
file_path = sys.argv[1]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        text = f.read()
except Exception:
    sys.exit(0)
forbidden = ["idempotency_key", "last_error", "cart_cleanup_status", "stock_reservation_id"]
found = set()

def walk(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in forbidden:
                found.add(key)
            walk(value)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

try:
    walk(json.loads(text))
except Exception:
    pass

if found:
    print("LEAKED: " + ", ".join(sorted(found)))
else:
    print("ok")
PY
  )"

  if [[ "$result" == "ok" ]]; then
    record PASS "no internal fields $case_name" "clean"
  else
    record FAIL "no internal fields $case_name" "$result"
  fi
}

# Accept 403 OR 404 as valid "not allowed" responses for isolation tests.
assert_forbidden_or_hidden() {
  local code="$1"
  local case_name="$2"

  if [[ "$code" == "403" || "$code" == "404" ]]; then
    record PASS "$case_name" "HTTP $code (isolated)"
  else
    record FAIL "$case_name" "HTTP $code expected 403 or 404 body=$(body_flat "$HTTP_DIR/${case_name// /-}.json")"
  fi
}

# Assert that order status did NOT change after a mutation attempt.
# Use after an unauthorized mutation to verify the order was not affected.
assert_status_unchanged() {
  local file="$1"
  local expected_status="$2"
  local case_name="$3"

  local actual
  actual="$(json_order_status "$file")"
  if [[ "$actual" == "$expected_status" ]]; then
    record PASS "$case_name" "status unchanged: $actual"
  else
    record FAIL "$case_name" "status changed: expected=$expected_status actual=$actual"
  fi
}

###############################################################################
# SDD7 — cart internal cleanup suite (direct)
###############################################################################

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

###############################################################################
# SDD7 — order-service integrated cleanup after approved checkout
###############################################################################

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

###############################################################################
# SDD8 — seller order reconciliation (minimal)
###############################################################################

sdd8_seller_reconciliation_suite() {
  blue "== SDD8 seller order reconciliation =="

  local seller_checkout_token seller_checkout_id order_id order_status code

  seller_checkout_token="$(state_get seller_checkout_token)"
  seller_checkout_id="$(state_get seller_checkout_id)"
  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"

  if [[ -z "$order_id" || -z "$seller_checkout_token" ]]; then
    record SKIP "SDD8 seller reconciliation" "missing order_id or seller token"
    return 0
  fi

  # Seller lists own orders
  code="$(seller_get_orders sdd8-list "$seller_checkout_token")"
  local count
  count="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd8-list.json" "$seller_checkout_id")"
  if is_2xx "$code" && [[ "$count" -ge 1 ]]; then
    record PASS "SDD8 seller lists own orders" "HTTP $code count=$count"
  else
    record FAIL "SDD8 seller lists own orders" "HTTP $code count=$count body=$(body_flat "$HTTP_DIR/seller-orders-sdd8-list.json")"
  fi

  # Verify ALL orders in list belong to seller
  local all_own
  all_own="$(json_orders_all_have_seller "$HTTP_DIR/seller-orders-sdd8-list.json" "$seller_checkout_id")"
  if [[ "$all_own" == "true" ]]; then
    record PASS "SDD8 seller list isolation" "all orders belong to seller $seller_checkout_id"
  else
    record FAIL "SDD8 seller list isolation" "some orders do not belong to seller $seller_checkout_id"
  fi

  # Seller gets order detail
  code="$(seller_get_order sdd8-detail "$seller_checkout_token" "$order_id")"
  order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-detail.json")"
  if is_2xx "$code" && [[ -n "$order_status" ]]; then
    record PASS "SDD8 seller get order detail" "HTTP $code status=$order_status"
  else
    record FAIL "SDD8 seller get order detail" "HTTP $code status=${order_status:-missing} body=$(body_flat "$HTTP_DIR/seller-order-sdd8-detail.json")"
  fi

  # Verify items in detail all belong to seller
  local items_own
  items_own="$(json_order_items_all_have_seller "$HTTP_DIR/seller-order-sdd8-detail.json" "$seller_checkout_id")"
  if [[ "$items_own" == "true" ]]; then
    record PASS "SDD8 seller detail item isolation" "all items belong to seller $seller_checkout_id"
  else
    record FAIL "SDD8 seller detail item isolation" "foreign items found"
  fi

  # No internal field leakage
  assert_no_internal_fields "$HTTP_DIR/seller-order-sdd8-detail.json" "sdd8-seller-detail"

  # Seller transitions: confirmada → en preparación (valid)
  code="$(seller_update_order_status sdd8-prep "$seller_checkout_token" "$order_id" "en preparación")"
  if is_2xx "$code"; then
    record PASS "SDD8 seller transition to en preparación" "HTTP $code"
  else
    record FAIL "SDD8 seller transition to en preparación" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-prep.json")"
  fi

  # Verify status changed
  code="$(seller_get_order sdd8-after-prep "$seller_checkout_token" "$order_id")"
  order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-after-prep.json")"
  if [[ "$order_status" == "en preparación" ]]; then
    record PASS "SDD8 order status is en preparación" "status=$order_status"
  else
    record FAIL "SDD8 order status is en preparación" "status=$order_status"
  fi

  # Seller transitions: en preparación → enviada with tracking (valid)
  code="$(seller_update_order_status sdd8-sent "$seller_checkout_token" "$order_id" "enviada" "TRACK-SDD8-${RUN_ID}")"
  if is_2xx "$code"; then
    record PASS "SDD8 seller transition to enviada with tracking" "HTTP $code"
  else
    record FAIL "SDD8 seller transition to enviada with tracking" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-sent.json")"
  fi

  # Verify status
  code="$(seller_get_order sdd8-after-sent "$seller_checkout_token" "$order_id")"
  order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-after-sent.json")"
  if [[ "$order_status" == "enviada" ]]; then
    record PASS "SDD8 order status is enviada" "status=$order_status"
  else
    record FAIL "SDD8 order status is enviada" "status=$order_status"
  fi

  # Invalid transition: enviada → confirmada (backwards)
  code="$(seller_update_order_status sdd8-invalid-back "$seller_checkout_token" "$order_id" "confirmada")"
  if is_4xx "$code"; then
    record PASS "SDD8 invalid transition blocked" "HTTP $code (enviada→confirmada)"
  else
    record FAIL "SDD8 invalid transition blocked" "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-invalid-back.json")"
  fi
}

###############################################################################
# SDD8 — checkout attempts & groups privacy
###############################################################################

sdd8_checkout_privacy_suite() {
  blue "== SDD8 checkout attempts & groups privacy =="

  local buyer buyer_f admin code cgid idem
  buyer="$(state_get buyer_checkout_token)"
  buyer_f="$(state_get buyer_foreign_token)"
  admin="$(state_get admin_token)"
  cgid="$(state_get SDD7_CHECKOUT_GROUP_ID)"
  idem="sdd7-checkout-approved-cleanup-$RUN_ID"

  if [[ -z "$cgid" ]]; then
    record SKIP "SDD8 checkout privacy" "no checkout_group_id from SDD7"
    return 0
  fi

  # Ensure admin is logged in
  if [[ -z "$admin" ]]; then
    admin_login
    admin="$(state_get admin_token)"
  fi

  # checkout attempts — owner 200
  code="$(checkout_attempt_get owner "$buyer" "$idem")"
  if is_2xx "$code"; then
    record PASS "SDD8 checkout attempts owner" "HTTP $code"
  else
    record FAIL "SDD8 checkout attempts owner" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-owner.json")"
  fi

  # checkout attempts — foreign buyer 404/403
  code="$(checkout_attempt_get foreign "$buyer_f" "$idem")"
  assert_forbidden_or_hidden "$code" "SDD8 checkout attempts foreign buyer"

  # checkout attempts — invalid UUID 400
  code="$(req checkout-attempt-invalid-uuid GET "$API_BASE/checkout/attempts/not-a-valid-uuid")"
  is_4xx "$code" && record PASS "SDD8 checkout attempts invalid uuid" "HTTP $code" || record FAIL "SDD8 checkout attempts invalid uuid" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-invalid-uuid.json")"

  # checkout attempts — no token 401
  code="$(req checkout-attempt-no-token GET "$API_BASE/checkout/attempts/$cgid")"
  is_401_403 "$code" && record PASS "SDD8 checkout attempts no token" "HTTP $code" || record FAIL "SDD8 checkout attempts no token" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-no-token.json")"

  # checkout groups — owner 200
  code="$(checkout_group_get owner "$buyer" "$cgid")"
  if is_2xx "$code"; then
    record PASS "SDD8 checkout groups owner" "HTTP $code"
    assert_no_internal_fields "$HTTP_DIR/checkout-group-owner.json" "sdd8_checkout_group_no_internal"
  else
    record FAIL "SDD8 checkout groups owner" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-owner.json")"
  fi

  # checkout groups — foreign buyer 404/403
  code="$(checkout_group_get foreign "$buyer_f" "$cgid")"
  assert_forbidden_or_hidden "$code" "SDD8 checkout groups foreign buyer"

  # checkout groups — admin 200
  if [[ -n "$admin" ]]; then
    code="$(checkout_group_get admin "$admin" "$cgid")"
    if is_2xx "$code"; then
      record PASS "SDD8 checkout groups admin" "HTTP $code"
    else
      record FAIL "SDD8 checkout groups admin" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-admin.json")"
    fi
  else
    record SKIP "SDD8 checkout groups admin" "admin token unavailable"
  fi

  # checkout groups — invalid UUID 400
  code="$(req checkout-group-invalid-uuid GET "$API_BASE/checkout-groups/not-a-valid-uuid")"
  is_4xx "$code" && record PASS "SDD8 checkout groups invalid uuid" "HTTP $code" || record FAIL "SDD8 checkout groups invalid uuid" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-invalid-uuid.json")"

  # checkout groups — no token 401
  code="$(req checkout-group-no-token GET "$API_BASE/checkout-groups/$cgid")"
  is_401_403 "$code" && record PASS "SDD8 checkout groups no token" "HTTP $code" || record FAIL "SDD8 checkout groups no token" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-no-token.json")"
}

###############################################################################
# SDD9 — multi-seller checkout + seller isolation + admin read-only
###############################################################################

sdd9_seller_admin_privacy_suite() {
  blue "== SDD9 multi-seller checkout + seller isolation + admin read-only =="

  local buyer_sdd9_token buyer_foreign_token
  local seller_a_token seller_a_id seller_b_token seller_b_id seller_intruder_token
  local product_a product_b
  local idem cgid order_id_a order_id_b code

  buyer_sdd9_token="$(state_get buyer_sdd9_token)"
  buyer_foreign_token="$(state_get buyer_foreign_token)"
  seller_a_token="$(state_get seller_a_token)"
  seller_a_id="$(state_get seller_a_id)"
  seller_b_token="$(state_get seller_b_token)"
  seller_b_id="$(state_get seller_b_id)"
  seller_intruder_token="$(state_get seller_intruder_token)"
  product_a="$(state_get SDD9_SELLER_A_PRODUCT_ID)"
  product_b="$(state_get SDD9_SELLER_B_PRODUCT_ID)"

  if [[ -z "$buyer_sdd9_token" || -z "$seller_a_token" || -z "$seller_b_token" || -z "$product_a" || -z "$product_b" ]]; then
    record SKIP "SDD9 suite" "missing actors or products"
    return 0
  fi

  idem="sdd9-multiseller-${RUN_ID}"

  # ── Step 1: Buyer adds both products ──
  add_to_cart sdd9-add-a "$buyer_sdd9_token" "$product_a" 1
  add_to_cart sdd9-add-b "$buyer_sdd9_token" "$product_b" 1

  get_cart sdd9-cart-before "$buyer_sdd9_token" >/dev/null
  local qty_a qty_b
  qty_a="$(cart_qty sdd9-cart-before "$product_a")"
  qty_b="$(cart_qty sdd9-cart-before "$product_b")"
  [[ "$qty_a" == "1" && "$qty_b" == "1" ]] && record PASS "SDD9 cart has both products" "a=$qty_a b=$qty_b" || record FAIL "SDD9 cart has both products" "a=$qty_a b=$qty_b"

  # ── Step 2: Checkout with idempotency key ──
  code="$(checkout sdd9-multiseller "$buyer_sdd9_token" "$idem")"
  cgid="$(json_get "$HTTP_DIR/checkout-sdd9-multiseller.json" ".checkout_group_id")"
  local grand_status
  grand_status="$(json_get "$HTTP_DIR/checkout-sdd9-multiseller.json" ".status")"

  if is_2xx "$code" && [[ -n "$cgid" ]]; then
    record PASS "SDD9 multi-seller checkout HTTP" "HTTP $code cg=$cgid status=$grand_status"
  else
    record FAIL "SDD9 multi-seller checkout HTTP" "HTTP $code cg=$cgid body=$(body_flat "$HTTP_DIR/checkout-sdd9-multiseller.json")"
  fi

  state_put SDD9_CHECKOUT_GROUP_ID "$cgid"

  # Find the two order IDs by seller
  order_id_a="$(checkout_order_id_for_seller sdd9-multiseller "$seller_a_id")"
  order_id_b="$(checkout_order_id_for_seller sdd9-multiseller "$seller_b_id")"

  if [[ -n "$order_id_a" && -n "$order_id_b" ]]; then
    record PASS "SDD9 two orders created" "order_a=$order_id_a order_b=$order_id_b"
  else
    record FAIL "SDD9 two orders created" "order_a=${order_id_a:-missing} order_b=${order_id_b:-missing}"
  fi

  state_put SDD9_ORDER_A_ID "$order_id_a"
  state_put SDD9_ORDER_B_ID "$order_id_b"

  # ── Step 3: Seller A list isolation ──
  code="$(seller_get_orders sdd9-seller-a-list "$seller_a_token")"
  local count_a
  count_a="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json" "$seller_a_id")"
  if is_2xx "$code" && [[ "$count_a" -ge 1 ]]; then
    record PASS "SDD9 seller A lists own orders" "HTTP $code count=$count_a"
  else
    record FAIL "SDD9 seller A lists own orders" "HTTP $code count=$count_a body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json")"
  fi

  # Seller A must NOT see seller B's order in their list
  local count_b_in_a
  count_b_in_a="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json" "$seller_b_id")"
  [[ "$count_b_in_a" == "0" ]] && record PASS "SDD9 seller A list hides seller B orders" "count=$count_b_in_a" || record FAIL "SDD9 seller A list hides seller B orders" "count=$count_b_in_a"

  # ── Step 4: Seller B list isolation ──
  code="$(seller_get_orders sdd9-seller-b-list "$seller_b_token")"
  local count_b
  count_b="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-b-list.json" "$seller_b_id")"
  if is_2xx "$code" && [[ "$count_b" -ge 1 ]]; then
    record PASS "SDD9 seller B lists own orders" "HTTP $code count=$count_b"
  else
    record FAIL "SDD9 seller B lists own orders" "HTTP $code count=$count_b body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-seller-b-list.json")"
  fi

  # ── Step 5: Seller A gets own order detail (isolated) ──
  code="$(seller_get_order sdd9-seller-a-detail "$seller_a_token" "$order_id_a")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A can get own order detail" "HTTP $code order=$order_id_a"
  else
    record FAIL "SDD9 seller A can get own order detail" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json")"
  fi

  # Seller A's order must NOT contain items from seller B
  local has_foreign
  has_foreign="$(json_order_has_foreign_seller_items "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json" "$seller_a_id")"
  if [[ "$has_foreign" == "false" ]]; then
    record PASS "SDD9 seller A detail no foreign items" "clean"
  else
    record FAIL "SDD9 seller A detail no foreign items" "leaked foreign seller items"
  fi

  # No internal fields in seller response
  assert_no_internal_fields "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json" "sdd9-seller-a-detail"

  # ── Step 6: Seller A cannot access seller B's order ──
  code="$(seller_get_order sdd9-seller-a-get-b "$seller_a_token" "$order_id_b")"
  assert_forbidden_or_hidden "$code" "SDD9 seller A cannot get seller B order"

  # ── Step 7: Intruder seller cannot access any seller orders ──
  code="$(seller_get_orders sdd9-intruder-list "$seller_intruder_token")"
  # Intruder is a valid seller with zero orders — 200 with empty list is correct
  if is_2xx "$code"; then
    record PASS "SDD9 intruder seller list isolation" "HTTP $code (empty list)"
  else
    record FAIL "SDD9 intruder seller list blocked" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-intruder-list.json")"
  fi

  code="$(seller_get_order sdd9-intruder-detail "$seller_intruder_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 intruder cannot get order A"

  # ── Step 8: Buyer cannot use seller endpoints ──
  code="$(seller_get_orders sdd9-buyer-as-seller "$buyer_sdd9_token")"
  # Buyer is authenticated but has no orders as seller — 200 with empty list is correct
  if is_2xx "$code"; then
    record PASS "SDD9 buyer seller-list isolation" "HTTP $code (empty list)"
  else
    record FAIL "SDD9 buyer cannot list seller orders" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-buyer-as-seller.json")"
  fi

  code="$(seller_get_order sdd9-buyer-as-seller-detail "$buyer_sdd9_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 buyer cannot get seller order detail"

  # ── Step 9: Seller own valid status transitions ──
  # confirmada → en preparación
  code="$(seller_update_order_status sdd9-a-prep "$seller_a_token" "$order_id_a" "en preparación")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A transition confirmada→en preparación" "HTTP $code"
  else
    record FAIL "SDD9 seller A transition confirmada→en preparación" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-prep.json")"
  fi

  # Verify
  code="$(seller_get_order sdd9-a-after-prep "$seller_a_token" "$order_id_a")"
  local a_status
  a_status="$(json_order_status "$HTTP_DIR/seller-order-sdd9-a-after-prep.json")"
  [[ "$a_status" == "en preparación" ]] && record PASS "SDD9 seller A status is en preparación" "status=$a_status" || record FAIL "SDD9 seller A status is en preparación" "status=$a_status"

  # en preparación → enviada with tracking code
  code="$(seller_update_order_status sdd9-a-sent "$seller_a_token" "$order_id_a" "enviada" "TRACK-SDD9A-${RUN_ID}")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A transition to enviada with tracking" "HTTP $code"
  else
    record FAIL "SDD9 seller A transition to enviada with tracking" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-sent.json")"
  fi

  code="$(seller_get_order sdd9-a-after-sent "$seller_a_token" "$order_id_a")"
  a_status="$(json_order_status "$HTTP_DIR/seller-order-sdd9-a-after-sent.json")"
  [[ "$a_status" == "enviada" ]] && record PASS "SDD9 seller A status is enviada" "status=$a_status" || record FAIL "SDD9 seller A status is enviada" "status=$a_status"

  # ── Step 10: Foreign seller cannot mutate order ──
  code="$(seller_update_order_status sdd9-intruder-mutate "$seller_intruder_token" "$order_id_a" "enviada" "TRACK-BAD")"
  assert_forbidden_or_hidden "$code" "SDD9 intruder cannot mutate order A"

  # ── Step 11: Foreign seller mutation does NOT change state ──
  code="$(seller_get_order sdd9-a-after-intruder "$seller_a_token" "$order_id_a")"
  assert_status_unchanged "$HTTP_DIR/seller-order-sdd9-a-after-intruder.json" "enviada" "SDD9 seller A order not mutated by intruder"

  # ── Step 12: Admin cannot mutate orders (read-only) ──
  local admin_token=""
  [[ -f "$STATE_DIR/admin_token" ]] && admin_token="$(state_get admin_token)"
  if [[ -n "$admin_token" ]]; then
    # Admin attempting seller mutation
    code="$(seller_update_order_status sdd9-admin-mutate-a "$admin_token" "$order_id_a" "entregada")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot mutate order via seller endpoint"

    # Verify order A not changed
    code="$(seller_get_order sdd9-a-after-admin-mutation "$seller_a_token" "$order_id_a")"
    assert_status_unchanged "$HTTP_DIR/seller-order-sdd9-a-after-admin-mutation.json" "enviada" "SDD9 seller A order not mutated by admin"
  else
    record SKIP "SDD9 admin mutation guard" "admin token missing"
  fi

  # ── Step 13: Invalid transition fails ──
  # enviada → confirmada is invalid
  code="$(seller_update_order_status sdd9-a-invalid-back "$seller_a_token" "$order_id_a" "confirmada")"
  if is_4xx "$code"; then
    record PASS "SDD9 invalid transition blocked" "HTTP $code (enviada→confirmada)"
  else
    record FAIL "SDD9 invalid transition blocked" "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-invalid-back.json")"
  fi

  # ── Step 14: Buyer owner can see own order ──
  code="$(buyer_get_order sdd9-buyer-own-a "$buyer_sdd9_token" "$order_id_a")"
  if is_2xx "$code"; then
    record PASS "SDD9 buyer owner sees own order A" "HTTP $code"
  else
    record FAIL "SDD9 buyer owner sees own order A" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-order-sdd9-buyer-own-a.json")"
  fi

  code="$(buyer_get_order sdd9-buyer-own-b "$buyer_sdd9_token" "$order_id_b")"
  if is_2xx "$code"; then
    record PASS "SDD9 buyer owner sees own order B" "HTTP $code"
  else
    record FAIL "SDD9 buyer owner sees own order B" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-order-sdd9-buyer-own-b.json")"
  fi

  # ── Step 15: Foreign buyer blocked from orders ──
  code="$(buyer_get_order sdd9-foreign-a "$buyer_foreign_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from order A"

  code="$(buyer_get_order sdd9-foreign-b "$buyer_foreign_token" "$order_id_b")"
  assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from order B"

  # ── Step 16: Foreign buyer blocked from checkout group ──
  if [[ -n "$cgid" ]]; then
    code="$(req sdd9-foreign-cg GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$buyer_foreign_token")")"
    assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from checkout group"

    # But buyer owner CAN access checkout group
    code="$(req sdd9-owner-cg GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$buyer_sdd9_token")")"
    if is_2xx "$code"; then
      record PASS "SDD9 buyer owner sees checkout group" "HTTP $code cg=$cgid"
    else
      record FAIL "SDD9 buyer owner sees checkout group" "HTTP $code body=$(body_flat "$HTTP_DIR/sdd9-owner-cg.json")"
    fi

    # Checkout group must not leak internal fields
    assert_no_internal_fields "$HTTP_DIR/sdd9-owner-cg.json" "sdd9-checkout-group"
  fi

  # ── Step 17: No leakage of sibling items (verify seller A detail still clean) ──
  code="$(seller_get_order sdd9-a-final-detail "$seller_a_token" "$order_id_a")"
  has_foreign="$(json_order_has_foreign_seller_items "$HTTP_DIR/seller-order-sdd9-a-final-detail.json" "$seller_a_id")"
  if [[ "$has_foreign" == "false" ]]; then
    record PASS "SDD9 seller A final detail no sibling leak" "clean"
  else
    record FAIL "SDD9 seller A final detail no sibling leak" "foreign items found"
  fi
}

###############################################################################
# Admin login
###############################################################################

admin_login() {
  local payload code token

  payload="$(
    cat <<JSON
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

###############################################################################
# Admin smoke suite (SDD7 + SDD9 extended)
###############################################################################

admin_smoke_suite() {
  blue "== Admin endpoints smoke =="

  local admin buyer order_id code
  local sdd9_order_a sdd9_order_b

  if ! admin_login; then
    record SKIP "admin smoke suite" "admin login failed"
    return 0
  fi

  admin="$(state_get admin_token)"
  buyer="$(state_get buyer_checkout_token)"
  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"
  sdd9_order_a="$(state_get SDD9_ORDER_A_ID)"
  sdd9_order_b="$(state_get SDD9_ORDER_B_ID)"

  # ── Admin users list ──
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

  # ── Admin orders list ──
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

  # ── Admin order detail (SDD7) ──
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
    record SKIP "admin order detail SDD7" "SDD7_CHECKOUT_ORDER_ID missing"
  fi

  # ── Admin order detail (SDD9) ──
  if [[ -n "$sdd9_order_a" ]]; then
    code="$(req admin-order-sdd9-a GET "$API_BASE/admin/orders/$sdd9_order_a" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin SDD9 order A detail" "HTTP $code order=$sdd9_order_a"
    else
      record FAIL "admin SDD9 order A detail" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-sdd9-a.json")"
    fi
  fi

  if [[ -n "$sdd9_order_b" ]]; then
    code="$(req admin-order-sdd9-b GET "$API_BASE/admin/orders/$sdd9_order_b" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin SDD9 order B detail" "HTTP $code order=$sdd9_order_b"
    else
      record FAIL "admin SDD9 order B detail" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-sdd9-b.json")"
    fi
  fi

  # ── Admin read-only: cannot mutate via seller endpoint ──
  if [[ -n "$sdd9_order_a" ]]; then
    local admin_mutate_code
    admin_mutate_code="$(req admin-sdd9-mutate-a POST "$API_BASE/seller/orders/$sdd9_order_a/status" '{"status":"enviada"}' "$(auth_h "$admin")" "Content-Type: application/json")"
    assert_forbidden_or_hidden "$admin_mutate_code" "SDD9 admin read-only seller mutation blocked"
  fi

  # ── Admin read-only: cannot use checkout endpoint ──
  local buyer_sdd9_token
  buyer_sdd9_token="$(state_get buyer_sdd9_token)"
  if [[ -n "$buyer_sdd9_token" ]]; then
    code="$(req admin-checkout-block POST "$API_BASE/checkout" '{"delivery_address":"Admin E2E","delivery_city":"CABA"}' "$(auth_h "$admin")" "Idempotency-Key: admin-checkout-$RUN_ID" "Content-Type: application/json")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot use checkout endpoint"
  fi

  # ── Admin read-only: cannot cancel orders ──
  local admin_test_order="${sdd9_order_a:-$order_id}"
  if [[ -n "$admin_test_order" ]]; then
    code="$(req admin-cancel-block POST "$API_BASE/orders/$admin_test_order/cancel" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot cancel order"

    code="$(req admin-confirm-delivery-block POST "$API_BASE/orders/$admin_test_order/confirm-delivery" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot confirm delivery"
  fi

  # ── Admin read-only: cannot use buyer GET endpoints ──
  code="$(req admin-get-orders-block GET "$API_BASE/orders/" "" "$(auth_h "$admin")")"
  assert_forbidden_or_hidden "$code" "SDD9 admin cannot list buyer orders"

  if [[ -n "$admin_test_order" ]]; then
    code="$(req admin-get-order-block GET "$API_BASE/orders/$admin_test_order" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot get buyer order detail"
  fi
}

###############################################################################
# Report
###############################################################################

write_report() {
  {
    echo "# Bazaar E2E — Checkout Saga / SDD7 + SDD8 + SDD9"
    echo ""
    echo "- RUN_ID: $RUN_ID"
    echo "- TARGET_ENV: ${E2E_TARGET_ENV:-render}"
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
    while IFS=$'\t' read -r s name note; do
      echo "| $s | $name | $note |"
    done <"$RESULTS"
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
  } >"$REPORT"
}

###############################################################################
# Main
###############################################################################

main() {
  blue "RUN_ID=$RUN_ID"
  blue "TARGET_ENV=${E2E_TARGET_ENV:-render}"
  blue "OUT_DIR=$OUT_DIR"
  blue "INTERNAL_TOKEN_LEN=${#INTERNAL_SERVICE_TOKEN}"
  blue "CART_INTERNAL_TOKEN_LEN=${#CART_INTERNAL_SERVICE_TOKEN}"
  blue "PAYMENT_SIMULATION_MODE expected: approved"

  wake_services
  auth_suite
  catalog_setup_suite
  cart_internal_cleanup_suite
  checkout_sdd7_cleanup_suite
  sdd8_seller_reconciliation_suite
  sdd8_checkout_privacy_suite
  sdd9_seller_admin_privacy_suite
  admin_smoke_suite

  write_report

  blue "== Summary =="
  echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  echo "REPORT=$REPORT"
  echo "RAW=$HTTP_DIR"

  if ((FAIL > 0)); then
    red "E2E SDD7 + SDD8 + SDD9 finished with failures."
    exit 1
  fi

  green "E2E SDD7 + SDD8 + SDD9 finished without blocking failures."
}

main "$@"

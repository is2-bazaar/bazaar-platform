#!/usr/bin/env bash
# e2e_catalog.sh — Catalog helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_CATALOG_SOURCED:-}" ]] && return 0
_E2E_CATALOG_SOURCED=1

# ---------------------------------------------------------------------------
# create_product — create a product via POST /catalog/me/products
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# list_my_products — list seller's own products
# ---------------------------------------------------------------------------
list_my_products() {
  local label="$1"
  local token="$2"
  req "catalog-list-mine-$label" GET "$API_BASE/catalog/me/products?page=1&page_size=100" "" "$(auth_h "$token")" >/dev/null
}

# ---------------------------------------------------------------------------
# public_get_product — fetch a product from the public catalog
# ---------------------------------------------------------------------------
public_get_product() {
  local label="$1"
  local product_id="$2"
  req "catalog-public-$label" GET "$API_BASE/catalog/products/$product_id"
}

# ---------------------------------------------------------------------------
# get_product_stock — query seller's own product listing endpoint and return
# the stock_quantity for a given product_id.
# Usage: get_product_stock <label> <token> <product_id>
# ---------------------------------------------------------------------------
get_product_stock() {
  local label="$1"
  local token="$2"
  local product_id="$3"

  list_my_products "$label" "$token"
  local file="$HTTP_DIR/catalog-list-mine-$label.json"

  python3 - "$file" "$product_id" <<'PY'
import json, sys
file_path = sys.argv[1]
product_id = str(sys.argv[2])
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

products = []
if isinstance(data, list):
    products = data
elif isinstance(data, dict):
    for key in ("products", "items", "data"):
        val = data.get(key)
        if isinstance(val, list):
            products = val
            break
    if not products and isinstance(data.get("data"), dict):
        for k2 in ("products", "items"):
            if isinstance(data["data"].get(k2), list):
                products = data["data"][k2]
                break

for p in products:
    if not isinstance(p, dict):
        continue
    pid = p.get("id") or p.get("ID")
    if str(pid) == product_id:
        sq = p.get("stock_quantity") or p.get("stock") or p.get("stockQuantity")
        if sq is not None:
            print(sq)
            sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# assert_stock_equals — simple numeric comparison assertion for stock values.
# Usage: assert_stock_equals <label> <actual> <expected>
# ---------------------------------------------------------------------------
assert_stock_equals() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$actual" == "$expected" ]]; then
    record PASS "stock $label" "stock=$actual"
  else
    record FAIL "stock $label" "expected=$expected actual=$actual"
  fi
}

# ---------------------------------------------------------------------------
# catalog_setup_suite — create all seed products and resolve their IDs
# ---------------------------------------------------------------------------
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

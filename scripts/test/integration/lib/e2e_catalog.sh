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

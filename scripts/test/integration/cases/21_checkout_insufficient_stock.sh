#!/usr/bin/env bash
# cases/21_checkout_insufficient_stock.sh — NEW: Checkout with insufficient stock returns 409
# Depends on: 01 (seller_direct, buyer_direct tokens), 10 (cart helpers)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_catalog.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"

case_21_checkout_insufficient_stock() {
  blue "--- 21_checkout_insufficient_stock ---"

  local seller_direct buyer_direct product_name product_id code
  seller_direct="$(state_get seller_direct_token)"
  buyer_direct="$(state_get buyer_direct_token)"

  if [[ -z "$seller_direct" || -z "$buyer_direct" ]]; then
    record SKIP "checkout insufficient stock" "missing seller_direct or buyer_direct tokens from case 01"
    return 0
  fi

  # Create a product with stock=1
  product_name="E2E_INSUFFICIENT_${RUN_ID}"
  create_product "$product_name" "$seller_direct" 99 1

  # Find its ID
  list_my_products seller_direct_insuff "$seller_direct"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_direct_insuff.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "insufficient stock product id" "could not find product '$product_name'"
    return 0
  fi

  record PASS "insufficient stock product id" "id=$product_id"
  state_put INSUFFICIENT_PRODUCT_ID "$product_id"

  # Add quantity 2 to cart (stock is only 1)
  add_to_cart insuff-stock-cart "$buyer_direct" "$product_id" 2

  # Attempt checkout
  local idem="insufficient-stock-checkout-$RUN_ID"
  state_put INSUFFICIENT_CHECKOUT_KEY "$idem"
  code="$(checkout insuff-stock "$buyer_direct" "$idem")"

  if [[ "$code" == "409" ]]; then
    record PASS "checkout insufficient stock returns 409" "HTTP $code"

    # Check response body has insufficient_stock detail
    local body_file="$HTTP_DIR/checkout-insuff-stock.json"
    local has_detail
    has_detail="$(json_field_exists "$body_file" "insufficient_stock_items")"

    if [[ "$has_detail" == "true" ]]; then
      record PASS "checkout insufficient stock detail present" "body has insufficient_stock_items"
    else
      # Try alternate field names
      local has_alt
      has_alt="$(json_field_exists "$body_file" "message")"
      if [[ "$has_alt" == "true" ]]; then
        record PASS "checkout insufficient stock has error message" "body has message field"
      else
        record SKIP "checkout insufficient stock detail shape" "insufficient_stock_items field not found; verify manually: $(body_flat "$body_file" | cut -c1-200)"
      fi
    fi

    # Verify no checkout_group confirmed
    local cgid
    cgid="$(json_get "$body_file" ".checkout_group_id")"
    if [[ -z "$cgid" ]]; then
      record PASS "checkout insufficient stock no checkout group created" "cgid absent"
    else
      record FAIL "checkout insufficient stock no checkout group created" "cgid=$cgid (unexpected)"
    fi

  elif [[ "$code" == "2"* ]]; then
    record FAIL "checkout insufficient stock returns 409" "HTTP $code (expected 409, got 2xx — stock check missing) body=$(body_flat "$HTTP_DIR/checkout-insuff-stock.json")"
  else
    record FAIL "checkout insufficient stock returns 409" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-insuff-stock.json")"
  fi
}

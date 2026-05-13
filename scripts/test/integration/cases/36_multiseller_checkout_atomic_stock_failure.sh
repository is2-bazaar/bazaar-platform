#!/usr/bin/env bash
# cases/36_multiseller_checkout_atomic_stock_failure.sh — Multi-seller checkout atomicity on stock failure
# Depends on: 01_auth_catalog_setup (seller_a, seller_b, buyer_sdd9 or fresh)
# Purpose: cart with Product A (stock ok) + Product B (stock depleted) must fail
# atomically — no partial confirmation of seller A's order.

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
source "$LIB_DIR/e2e_orders.sh"

case_36_multiseller_checkout_atomic_stock_failure() {
  blue "--- 36_multiseller_checkout_atomic_stock_failure ---"

  local seller_a seller_b buyer
  local product_a product_b
  local code idem cgid

  seller_a="$(state_get seller_a_token)"
  seller_b="$(state_get seller_b_token)"
  buyer="$(state_get buyer_sdd9_token)"

  if [[ -z "$seller_a" || -z "$seller_b" ]]; then
    register_user seller_atomic_a "seller"
    register_user seller_atomic_b "seller"
    seller_a="$(state_get seller_atomic_a_token)"
    seller_b="$(state_get seller_atomic_b_token)"
  fi

  if [[ -z "$buyer" ]]; then
    register_user buyer_atomic
    buyer="$(state_get buyer_atomic_token)"
  fi

  if [[ -z "$seller_a" || -z "$seller_b" || -z "$buyer" ]]; then
    record SKIP "multiseller atomic" "missing actors"
    return 0
  fi

  # Seller A creates product with stock=5  (will be the "good" one)
  # Seller B creates product with stock=1  (will be depleted)
  local prod_name_a="E2E_ATOM_A_${RUN_ID}"
  local prod_name_b="E2E_ATOM_B_${RUN_ID}"
  create_product "$prod_name_a" "$seller_a" 150 5
  create_product "$prod_name_b" "$seller_b" 200 1

  list_my_products seller_atomic_a_list "$seller_a"
  list_my_products seller_atomic_b_list "$seller_b"

  product_a="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_atomic_a_list.json" "$prod_name_a")"
  product_b="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_atomic_b_list.json" "$prod_name_b")"

  if [[ -z "$product_a" || -z "$product_b" ]]; then
    record FAIL "multiseller atomic products" "missing product_a=$product_a product_b=$product_b"
    return 0
  fi

  record PASS "multiseller atomic products created" "a=$product_a b=$product_b"

  # Buyer adds both to cart
  add_to_cart atomic-cart-a "$buyer" "$product_a" 1
  add_to_cart atomic-cart-b "$buyer" "$product_b" 1

  get_cart atomic-cart-before "$buyer" >/dev/null
  local qa qb
  qa="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-atomic-cart-before.json" "$product_a")"
  qb="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-atomic-cart-before.json" "$product_b")"
  [[ "$qa" == "1" && "$qb" == "1" ]] && record PASS "multiseller atomic cart ready" "a=$qa b=$qb" ||
    record FAIL "multiseller atomic cart ready" "a=$qa b=$qb"

  # Deplete stock of Product B using a concurrent buyer
  register_user buyer_atomic_depleter
  local depleter
  depleter="$(state_get buyer_atomic_depleter_token)"

  if [[ -n "$depleter" ]]; then
    add_to_cart atomic-deplete-cart "$depleter" "$product_b" 1 2>/dev/null || true
    code="$(checkout atomic-deplete "$depleter" "atomic-deplete-$RUN_ID")"
    if is_2xx "$code"; then
      record PASS "multiseller atomic depleted stock B" "HTTP $code — stock B should be 0"
      local depleted_cgid
      depleted_cgid="$(json_get "$HTTP_DIR/checkout-atomic-deplete.json" ".checkout_group_id")"
      record PASS "multiseller atomic depleter checkout" "cgid=$depleted_cgid"
    else
      record SKIP "multiseller atomic depleted stock B" \
        "HTTP $code — could not deplete via concurrent buyer; trying checkout anyway"
    fi
  else
    record SKIP "multiseller atomic depleter" "could not register concurrent buyer"
  fi

  # Now the original buyer attempts checkout with both products
  idem="atomic-multiseller-$RUN_ID"
  code="$(checkout atomic-checkout "$buyer" "$idem")"

  if is_2xx "$code"; then
    cgid="$(json_get "$HTTP_DIR/checkout-atomic-checkout.json" ".checkout_group_id")"
    # Check whether this is a true failure or a success that shouldn't happen
    if [[ -z "$cgid" ]]; then
      record PASS "multiseller atomic checkout blocked" \
        "HTTP $code but no cgid — system may 2xx with no checkout on partial stock"
    else
      record FAIL "multiseller atomic checkout blocked" \
        "HTTP $code cgid=$cgid — checkout succeeded despite stock depletion on one product. Partial confirmation?"
    fi
  elif [[ "$code" == "409" ]]; then
    record PASS "multiseller atomic checkout returns 409" "HTTP $code — conflict as expected"

    # Verify no cgid in response
    cgid="$(json_get "$HTTP_DIR/checkout-atomic-checkout.json" ".checkout_group_id")"
    if [[ -z "$cgid" ]]; then
      record PASS "multiseller atomic no cgid" "cgid absent"
    else
      record FAIL "multiseller atomic no cgid" "cgid=$cgid (should not exist)"
    fi
  elif is_4xx "$code"; then
    record PASS "multiseller atomic checkout rejected" "HTTP $code"

    cgid="$(json_get "$HTTP_DIR/checkout-atomic-checkout.json" ".checkout_group_id")"
    if [[ -z "$cgid" ]]; then
      record PASS "multiseller atomic no cgid" "cgid absent"
    else
      record FAIL "multiseller atomic no cgid" "cgid=$cgid (should not exist)"
    fi
  else
    record FAIL "multiseller atomic checkout rejected" \
      "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/checkout-atomic-checkout.json")"
    return 0
  fi

  # Verify cart is NOT cleaned — Product A should still be there
  get_cart atomic-cart-after "$buyer" >/dev/null
  qa="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-atomic-cart-after.json" "$product_a")"
  if [[ "$qa" == "1" ]]; then
    record PASS "multiseller atomic cart preserved product A" "qty=$qa"
  else
    record FAIL "multiseller atomic cart preserved product A" "qty=$qa expected=1 — cart was cleaned partially"
  fi

  # Verify no orders were created for the original buyer
  code="$(buyer_get_orders atomic-buyer-orders "$buyer")"
  if is_2xx "$code"; then
    local has_order_b
    has_order_b="$(json_field_exists "$HTTP_DIR/buyer-orders-atomic-buyer-orders.json" "order_id")"
    if [[ "$has_order_b" != "true" ]]; then
      record PASS "multiseller atomic no orders for original buyer" "no order_id found (expected)"
    else
      record FAIL "multiseller atomic no orders for original buyer" "buyer has orders despite failed checkout"
    fi
  else
    record SKIP "multiseller atomic no orders verification" "HTTP $code — cannot verify orders list"
  fi
}

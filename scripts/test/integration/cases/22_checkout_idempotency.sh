#!/usr/bin/env bash
# cases/22_checkout_idempotency.sh — NEW: Checkout idempotency preserves result
# Depends on: 01 (buyer_checkout, seller_checkout), 20 is NOT required

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

case_22_checkout_idempotency() {
  blue "--- 22_checkout_idempotency ---"

  local seller_checkout buyer_checkout product_name product_id code
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "checkout idempotency" "missing seller_checkout or buyer_checkout tokens from case 01"
    return 0
  fi

  # Create a product with stock=10
  product_name="E2E_IDEMPOTENT_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 199 10

  list_my_products seller_checkout_idem "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_checkout_idem.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "idempotency product id" "could not find product '$product_name'"
    return 0
  fi

  record PASS "idempotency product created" "id=$product_id"

  # Add to cart and checkout
  add_to_cart idemp-cart "$buyer_checkout" "$product_id" 2

  local idem="idempotent-checkout-${RUN_ID}"
  code="$(checkout idemp-first "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "idempotency first checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-idemp-first.json")"
    return 0
  fi

  local cgid1 order_id1
  cgid1="$(json_get "$HTTP_DIR/checkout-idemp-first.json" ".checkout_group_id")"
  order_id1="$(order_id_first idemp-first)"

  if [[ -z "$cgid1" ]]; then
    record FAIL "idempotency first checkout" "no checkout_group_id"
    return 0
  fi

  record PASS "idempotency first checkout" "cg=$cgid1 order=$order_id1"
  state_put CHECKOUT_IDEMPOTENCY_GROUP_ID "$cgid1"
  state_put CHECKOUT_IDEMPOTENCY_ORDER_ID "$order_id1"

  # Retry with SAME idempotency key (don't re-add items)
  code="$(checkout idemp-retry "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "idempotency retry is not 2xx" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-idemp-retry.json")"
    return 0
  fi

  local cgid2 order_id2
  cgid2="$(json_get "$HTTP_DIR/checkout-idemp-retry.json" ".checkout_group_id")"
  order_id2="$(order_id_first idemp-retry)"

  if [[ "$cgid1" == "$cgid2" ]]; then
    record PASS "checkout idempotency same checkout_group_id" "cg1=$cgid1 cg2=$cgid2"
  else
    record FAIL "checkout idempotency same checkout_group_id" "cg1=$cgid1 cg2=$cgid2"
  fi

  if [[ "$order_id1" == "$order_id2" ]]; then
    record PASS "checkout idempotency same order_id" "oid1=$order_id1 oid2=$order_id2"
  else
    record FAIL "checkout idempotency same order_id" "oid1=$order_id1 oid2=$order_id2"
  fi

  # Re-add to cart and retry with same key — should NOT delete re-added items
  get_cart idemp-cart-before-readd "$buyer_checkout" >/dev/null
  add_to_cart idemp-readd "$buyer_checkout" "$product_id" 3
  get_cart idemp-cart-after-readd "$buyer_checkout" >/dev/null

  # Verify items are there
  local qty_after_readd
  qty_after_readd="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-idemp-cart-after-readd.json" "$product_id")"
  [[ "$qty_after_readd" == "3" ]] && record PASS "idempotency re-add cart has items" "qty=$qty_after_readd" \
    || record FAIL "idempotency re-add cart has items" "qty=$qty_after_readd expected=3"

  # Retry checkout with same key
  code="$(checkout idemp-retry-after-readd "$buyer_checkout" "$idem")"
  if is_2xx "$code"; then
    record PASS "checkout retry after re-add HTTP" "HTTP $code"
  else
    record FAIL "checkout retry after re-add HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-idemp-retry-after-readd.json")"
  fi

  # Verify re-added items were NOT deleted
  get_cart idemp-cart-after-retry "$buyer_checkout" >/dev/null
  local qty_after_retry
  qty_after_retry="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-idemp-cart-after-retry.json" "$product_id")"
  [[ "$qty_after_retry" == "3" ]] && record PASS "checkout idempotency does not delete re-added items" "qty=$qty_after_retry" \
    || record FAIL "checkout idempotency does not delete re-added items" "qty=$qty_after_retry expected=3"
}

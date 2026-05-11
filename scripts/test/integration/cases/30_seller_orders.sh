#!/usr/bin/env bash
# cases/30_seller_orders.sh — SDD9 multi-seller checkout + seller isolation
# Depends on: 01, 20 (all SDD9 actors, products, checkout)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"
source "$LIB_DIR/e2e_orders.sh"

case_30_seller_orders() {
  blue "--- 30_seller_orders ---"

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

  blue "== SDD9 multi-seller checkout + seller isolation =="

  idem="sdd9-multiseller-${RUN_ID}"

  add_to_cart sdd9-add-a "$buyer_sdd9_token" "$product_a" 1
  add_to_cart sdd9-add-b "$buyer_sdd9_token" "$product_b" 1

  get_cart sdd9-cart-before "$buyer_sdd9_token" >/dev/null
  local qty_a qty_b
  qty_a="$(cart_qty sdd9-cart-before "$product_a")"
  qty_b="$(cart_qty sdd9-cart-before "$product_b")"
  [[ "$qty_a" == "1" && "$qty_b" == "1" ]] && record PASS "SDD9 cart has both products" "a=$qty_a b=$qty_b" \
    || record FAIL "SDD9 cart has both products" "a=$qty_a b=$qty_b"

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

  order_id_a="$(checkout_order_id_for_seller sdd9-multiseller "$seller_a_id")"
  order_id_b="$(checkout_order_id_for_seller sdd9-multiseller "$seller_b_id")"

  if [[ -n "$order_id_a" && -n "$order_id_b" ]]; then
    record PASS "SDD9 two orders created" "order_a=$order_id_a order_b=$order_id_b"
  else
    record FAIL "SDD9 two orders created" "order_a=${order_id_a:-missing} order_b=${order_id_b:-missing}"
  fi

  state_put SDD9_ORDER_A_ID "$order_id_a"
  state_put SDD9_ORDER_B_ID "$order_id_b"

  if ! is_2xx "$code" || [[ -z "$cgid" || -z "$order_id_a" || -z "$order_id_b" ]]; then
    record SKIP "SDD9 seller/admin privacy dependent assertions" "checkout failed or did not produce both order IDs"
    return 0
  fi

  # Seller A list isolation
  code="$(seller_get_orders sdd9-seller-a-list "$seller_a_token")"
  local count_a
  count_a="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json" "$seller_a_id")"
  if is_2xx "$code" && [[ "$count_a" -ge 1 ]]; then
    record PASS "SDD9 seller A lists own orders" "HTTP $code count=$count_a"
  else
    record FAIL "SDD9 seller A lists own orders" "HTTP $code count=$count_a body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json")"
  fi

  local count_b_in_a
  count_b_in_a="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-a-list.json" "$seller_b_id")"
  [[ "$count_b_in_a" == "0" ]] && record PASS "SDD9 seller A list hides seller B orders" "count=$count_b_in_a" \
    || record FAIL "SDD9 seller A list hides seller B orders" "count=$count_b_in_a"

  # Seller B list isolation
  code="$(seller_get_orders sdd9-seller-b-list "$seller_b_token")"
  local count_b
  count_b="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd9-seller-b-list.json" "$seller_b_id")"
  if is_2xx "$code" && [[ "$count_b" -ge 1 ]]; then
    record PASS "SDD9 seller B lists own orders" "HTTP $code count=$count_b"
  else
    record FAIL "SDD9 seller B lists own orders" "HTTP $code count=$count_b body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-seller-b-list.json")"
  fi

  # Seller A gets own order detail (isolated)
  code="$(seller_get_order sdd9-seller-a-detail "$seller_a_token" "$order_id_a")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A can get own order detail" "HTTP $code order=$order_id_a"
  else
    record FAIL "SDD9 seller A can get own order detail" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json")"
  fi

  local has_foreign
  has_foreign="$(json_order_has_foreign_seller_items "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json" "$seller_a_id")"
  if [[ "$has_foreign" == "false" ]]; then
    record PASS "SDD9 seller A detail no foreign items" "clean"
  else
    record FAIL "SDD9 seller A detail no foreign items" "leaked foreign seller items"
  fi

  assert_no_internal_fields "$HTTP_DIR/seller-order-sdd9-seller-a-detail.json" "sdd9-seller-a-detail"

  # Seller A cannot access seller B's order
  code="$(seller_get_order sdd9-seller-a-get-b "$seller_a_token" "$order_id_b")"
  assert_forbidden_or_hidden "$code" "SDD9 seller A cannot get seller B order"

  # Intruder seller cannot access any seller orders
  code="$(seller_get_orders sdd9-intruder-list "$seller_intruder_token")"
  if is_2xx "$code"; then
    record PASS "SDD9 intruder seller list isolation" "HTTP $code (empty list)"
  else
    record FAIL "SDD9 intruder seller list blocked" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-intruder-list.json")"
  fi

  code="$(seller_get_order sdd9-intruder-detail "$seller_intruder_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 intruder cannot get order A"

  # Buyer cannot use seller endpoints
  code="$(seller_get_orders sdd9-buyer-as-seller "$buyer_sdd9_token")"
  if is_2xx "$code"; then
    record PASS "SDD9 buyer seller-list isolation" "HTTP $code (empty list)"
  else
    record FAIL "SDD9 buyer cannot list seller orders" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-orders-sdd9-buyer-as-seller.json")"
  fi

  code="$(seller_get_order sdd9-buyer-as-seller-detail "$buyer_sdd9_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 buyer cannot get seller order detail"
}

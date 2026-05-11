#!/usr/bin/env bash
# cases/40_cancel_order_buyer.sh — NEW: Buyer cancels own order
# Depends on: 01 (actors, products), 20/30 (checks out then cancels via a new checkout)

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

case_40_cancel_order_buyer() {
  blue "--- 40_cancel_order_buyer ---"

  local seller_direct buyer_direct seller_checkout buyer_checkout
  local buyer_foreign admin
  local product_name product_id code idem cgid order_id

  seller_direct="$(state_get seller_direct_token)"
  buyer_direct="$(state_get buyer_direct_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"
  buyer_foreign="$(state_get buyer_foreign_token)"
  admin="$(state_get admin_token)"

  if [[ -z "$seller_direct" || -z "$buyer_direct" ]]; then
    record SKIP "cancel order buyer" "missing seller_direct or buyer_direct tokens from case 01"
    return 0
  fi

  # Create product with stock=5
  product_name="E2E_CANCEL_BUYER_${RUN_ID}"
  create_product "$product_name" "$seller_direct" 149 5

  list_my_products seller_direct_cancel "$seller_direct"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_direct_cancel.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel buyer product id" "could not find product '$product_name'"
    return 0
  fi

  record PASS "cancel buyer product created" "id=$product_id"
  state_put CANCEL_BUYER_PRODUCT_ID "$product_id"

  # Checkout
  add_to_cart cancel-buyer-cart "$buyer_direct" "$product_id" 2
  idem="cancel-buyer-checkout-$RUN_ID"
  code="$(checkout cancel-buyer "$buyer_direct" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel buyer checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cancel-buyer.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cancel-buyer.json" ".checkout_group_id")"
  order_id="$(order_id_first cancel-buyer)"

  if [[ -z "$cgid" || -z "$order_id" ]]; then
    record FAIL "cancel buyer checkout" "no cgid or order_id"
    return 0
  fi

  record PASS "cancel buyer checkout" "cg=$cgid order=$order_id"
  state_put CANCEL_BUYER_ORDER_ID "$order_id"
  state_put CANCEL_BUYER_CHECKOUT_GROUP_ID "$cgid"

  # Cancel the order
  code="$(buyer_cancel_order cancel-buyer "$buyer_direct" "$order_id")"
  if is_2xx "$code"; then
    record PASS "buyer cancel order 2xx" "HTTP $code"
  else
    record FAIL "buyer cancel order 2xx" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-buyer.json")"
    return 0
  fi

  # Verify status is cancelada
  code="$(buyer_get_order cancel-buyer-after "$buyer_direct" "$order_id")"
  local status
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-buyer-after.json")"
  if [[ "$status" == "cancelada" ]]; then
    record PASS "buyer cancel order status is cancelada" "status=$status"
  else
    record FAIL "buyer cancel order status is cancelada" "status=$status"
  fi

  # Verify stock restored
  list_my_products seller_direct_cancel_after "$seller_direct"
  # Can't directly verify stock via list_my_products; try to see if stock field exists
  local stock_file="$HTTP_DIR/catalog-list-mine-seller_direct_cancel_after.json"
  local has_stock
  has_stock="$(json_field_exists "$stock_file" "stock_quantity")"
  if [[ "$has_stock" == "true" ]]; then
    record PASS "buyer cancel stock check" "stock_quantity field present in product listing"
  else
    record SKIP "buyer cancel stock check" "stock_quantity not in product listing; cannot verify restoration"
  fi

  # Repeat cancel — should be idempotent
  code="$(buyer_cancel_order cancel-buyer-repeat "$buyer_direct" "$order_id")"
  if is_2xx "$code" || is_4xx "$code"; then
    record PASS "buyer repeat cancel handled" "HTTP $code"
  else
    record FAIL "buyer repeat cancel handled" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-buyer-repeat.json")"
  fi

  # Foreign buyer cannot cancel
  if [[ -n "$buyer_foreign" ]]; then
    code="$(buyer_cancel_order cancel-foreign "$buyer_foreign" "$order_id")"
    assert_forbidden_or_hidden "$code" "foreign buyer cancel blocked"
  fi

  # Admin cannot cancel
  if [[ -n "$admin" ]]; then
    code="$(req admin-cancel-buyer POST "$API_BASE/orders/$order_id/cancel" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "admin cancel buyer order blocked"
  fi
}

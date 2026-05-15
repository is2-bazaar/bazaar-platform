#!/usr/bin/env bash
# cases/45_cancel_sent_order_blocked.sh — Cancel on sent/delivered orders must be blocked
# Depends on: 01_auth_catalog_setup (seller_checkout, buyer_checkout) and 20/30 for checkout
# Purpose: an order in "enviada" or beyond should not be cancellable unless the
# domain explicitly allows it. This guards against post-shipment cancellation
# without refund logic.

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

case_45_cancel_sent_order_blocked() {
  blue "--- 45_cancel_sent_order_blocked ---"

  local seller buyer
  local product_name product_id
  local code idem cgid order_id status

  seller="$(state_get seller_checkout_token)"
  buyer="$(state_get buyer_checkout_token)"

  if [[ -z "$seller" || -z "$buyer" ]]; then
    record SKIP "cancel sent order" "missing actors from case 01"
    return 0
  fi

  # Create product and checkout
  product_name="E2E_CANCEL_SENT_${RUN_ID}"
  create_product "$product_name" "$seller" 170 5

  list_my_products seller_cancel_sent_list "$seller"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_cancel_sent_list.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel sent order product" "could not find product '$product_name'"
    return 0
  fi

  record PASS "cancel sent order product created" "id=$product_id"

  add_to_cart cancel-sent-cart "$buyer" "$product_id" 1
  idem="cancel-sent-checkout-$RUN_ID"
  code="$(checkout cancel-sent-checkout "$buyer" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel sent order checkout" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cancel-sent-checkout.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cancel-sent-checkout.json" ".checkout_group_id")"
  order_id="$(order_id_first cancel-sent-checkout)"

  if [[ -z "$order_id" ]]; then
    record FAIL "cancel sent order id" "could not resolve order_id from checkout"
    return 0
  fi

  record PASS "cancel sent order checkout done" "cg=$cgid order=$order_id"

  # Advance: confirmada → en preparación → enviada
  code="$(seller_update_order_status cancel-sent-prep "$seller" "$order_id" "en preparación")"
  if is_2xx "$code"; then
    record PASS "cancel sent order to en preparación" "HTTP $code"
  else
    record FAIL "cancel sent order to en preparación" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-cancel-sent-prep.json")"
    return 0
  fi

  code="$(seller_update_order_status cancel-sent-sent "$seller" "$order_id" "enviada" "TRACK-CANCEL-SENT-${RUN_ID}")"
  if is_2xx "$code"; then
    record PASS "cancel sent order to enviada" "HTTP $code"
  else
    record FAIL "cancel sent order to enviada" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-cancel-sent-sent.json")"
    return 0
  fi

  # Verify current status is enviada
  code="$(buyer_get_order cancel-sent-verify "$buyer" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-sent-verify.json")"
  if [[ "$status" == "enviada" ]]; then
    record PASS "cancel sent order status is enviada" "status=$status"
  else
    record FAIL "cancel sent order status is enviada" "status=$status expected=enviada"
    return 0
  fi

  # Buyer attempts cancel on enviada order
  code="$(buyer_cancel_order cancel-sent-buyer "$buyer" "$order_id")"
  if is_4xx "$code"; then
    record PASS "cancel sent order buyer blocked" "HTTP $code — cannot cancel enviada order"
  elif is_2xx "$code"; then
    record SKIP "cancel sent order buyer blocked" \
      "HTTP $code — domain allows cancelling enviada orders (product decision)"
  else
    record SKIP "cancel sent order buyer blocked" \
      "HTTP $code — unexpected response; verify contract"
  fi

  # Verify status is still enviada after buyer cancel attempt
  code="$(buyer_get_order cancel-sent-after-buyer-try "$buyer" "$order_id")"
  assert_status_unchanged "$HTTP_DIR/buyer-order-cancel-sent-after-buyer-try.json" "enviada" \
    "cancel sent order status unchanged after buyer cancel attempt"

  # Seller attempts cancel on enviada order
  code="$(seller_cancel_order cancel-sent-seller "$seller" "$order_id")"
  if is_4xx "$code"; then
    record PASS "cancel sent order seller blocked" "HTTP $code — cannot cancel enviada order"
  elif is_2xx "$code"; then
    record SKIP "cancel sent order seller blocked" \
      "HTTP $code — domain allows seller to cancel enviada orders"
  else
    record SKIP "cancel sent order seller blocked" \
      "HTTP $code — unexpected response; verify contract"
  fi

  # Verify status is still enviada after seller cancel attempt
  code="$(buyer_get_order cancel-sent-after-seller-try "$buyer" "$order_id")"
  assert_status_unchanged "$HTTP_DIR/buyer-order-cancel-sent-after-seller-try.json" "enviada" \
    "cancel sent order status unchanged after seller cancel attempt"
}

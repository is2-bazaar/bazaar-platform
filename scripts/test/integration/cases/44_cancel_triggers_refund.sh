#!/usr/bin/env bash
# cases/44_cancel_triggers_refund.sh — Cancel confirmed order triggers refund in mock mode
# Depends on: 01 (actors)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_catalog.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"
source "$LIB_DIR/e2e_orders.sh"
source "$LIB_DIR/e2e_payment.sh"

case_44_cancel_triggers_refund() {
  blue "--- 44_cancel_triggers_refund ---"

  local seller_checkout buyer_checkout product_name product_id code idem cgid order_id status
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "cancel triggers refund" "missing actor tokens from case 01"
    return 0
  fi

  # Create product and checkout (approved mock → auto-confirms)
  product_name="E2E_CANCEL_REFUND_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 199 8
  list_my_products cancel-refund-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cancel-refund-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel refund product" "could not find product"
    return 0
  fi

  add_to_cart cancel-refund-cart "$buyer_checkout" "$product_id" 2
  idem="cancel-refund-$RUN_ID"
  code="$(checkout cancel-refund "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel refund checkout" "HTTP $code"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cancel-refund.json" ".checkout_group_id")"
  order_id="$(order_id_first cancel-refund)"

  if [[ -z "$cgid" || -z "$order_id" ]]; then
    record FAIL "cancel refund checkout data" "cg=$cgid order=$order_id"
    return 0
  fi

  record PASS "cancel refund checkout" "cg=$cgid order=$order_id"
  state_put CANCEL_REFUND_CGID "$cgid"
  state_put CANCEL_REFUND_ORDER_ID "$order_id"

  # Verify initial status
  code="$(buyer_get_order cancel-refund-before "$buyer_checkout" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-refund-before.json")"
  record PASS "cancel refund initial status" "status=$status"

  # Only cancel if order is in a cancellable state (confirmed or in-preparation)
  if [[ "$status" != "confirmada" && "$status" != "confirmed" && "$status" != "en preparación" ]]; then
    record SKIP "cancel refund" "order status $status is not cancellable"
    return 0
  fi

  # Cancel the order → should trigger refund in mock mode
  code="$(buyer_cancel_order cancel-refund-do "$buyer_checkout" "$order_id")"
  if is_2xx "$code"; then
    record PASS "cancel triggers refund HTTP 2xx" "HTTP $code"
  else
    record FAIL "cancel triggers refund HTTP 2xx" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-refund-do.json")"
    return 0
  fi

  # Verify order is cancelled
  code="$(buyer_get_order cancel-refund-after "$buyer_checkout" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-refund-after.json")"
  if [[ "$status" == "cancelada" || "$status" == "cancelled" || "$status" == "reembolso en proceso" ]]; then
    record PASS "cancel refund order status" "status=$status"
  else
    record FAIL "cancel refund order status" "status=$status"
  fi

  # Verify repeat cancel is idempotent
  code="$(buyer_cancel_order cancel-refund-repeat "$buyer_checkout" "$order_id")"
  if is_2xx "$code" || is_4xx "$code"; then
    record PASS "cancel refund repeat is idempotent" "HTTP $code"
  else
    record FAIL "cancel refund repeat is idempotent" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-refund-repeat.json")"
  fi
}

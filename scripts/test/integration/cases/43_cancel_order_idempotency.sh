#!/usr/bin/env bash
# cases/43_cancel_order_idempotency.sh — NEW: Cancel order idempotency
# Depends on: 40 (CANCEL_BUYER_ORDER_ID for buyer_cancel flow)

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

case_43_cancel_order_idempotency() {
  blue "--- 43_cancel_order_idempotency ---"

  local seller_checkout buyer_checkout
  local product_name product_id code idem cgid order_id

  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "cancel order idempotency" "missing seller_checkout or buyer_checkout tokens from case 01"
    return 0
  fi

  # Create fresh product and order
  product_name="E2E_CANCEL_IDEMP_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 349 5

  list_my_products seller_checkout_idemp "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_checkout_idemp.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel idempotency product id" "could not find product '$product_name'"
    return 0
  fi

  record PASS "cancel idempotency product created" "id=$product_id"

  # Checkout
  add_to_cart cancel-idemp-cart "$buyer_checkout" "$product_id" 2
  idem="cancel-idemp-checkout-$RUN_ID"
  code="$(checkout cancel-idemp "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel idempotency checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cancel-idemp.json")"
    return 0
  fi

  order_id="$(order_id_first cancel-idemp)"

  if [[ -z "$order_id" ]]; then
    record FAIL "cancel idempotency order id" "no order_id from checkout"
    return 0
  fi

  record PASS "cancel idempotency checkout" "order=$order_id"

  # First cancel
  code="$(buyer_cancel_order cancel-idemp-first "$buyer_checkout" "$order_id")"
  if is_2xx "$code"; then
    record PASS "cancel idempotency first cancel" "HTTP $code"
  else
    record FAIL "cancel idempotency first cancel" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-idemp-first.json")"
    return 0
  fi

  # Second cancel — should be idempotent
  code="$(buyer_cancel_order cancel-idemp-second "$buyer_checkout" "$order_id")"
  if is_2xx "$code" || is_4xx "$code"; then
    record PASS "cancel idempotency second cancel handled" "HTTP $code"
  else
    record FAIL "cancel idempotency second cancel handled" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-idemp-second.json")"
  fi

  # Final status should be a terminal cancel/refund state
  code="$(buyer_get_order cancel-idemp-final "$buyer_checkout" "$order_id")"
  local final_status
  final_status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-idemp-final.json")"
  if [[ "$final_status" == "cancelada" || "$final_status" == "reembolso en proceso" || "$final_status" == "reembolso procesado" ]]; then
    record PASS "cancel idempotency final status is terminal cancel/refund" "status=$final_status"
  else
    record FAIL "cancel idempotency final status is terminal cancel/refund" "status=$final_status"
  fi

  # Check history if available — count cancelada entries (skip if not exposed)
  local history_count
  history_count="$(json_count_history_status "$HTTP_DIR/buyer-order-cancel-idemp-final.json" "cancelada")"
  if [[ "$history_count" != "0" ]]; then
    # If history is exposed, ensure cancelada appears at least once
    if [[ "$history_count" -ge 1 ]]; then
      record PASS "cancel idempotency history has cancelada" "count=$history_count"
    else
      record FAIL "cancel idempotency history has cancelada" "count=$history_count"
    fi
  else
    record SKIP "cancel idempotency history check" "history not exposed or empty"
  fi
}

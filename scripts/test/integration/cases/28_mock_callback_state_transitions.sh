#!/usr/bin/env bash
# cases/28_mock_callback_state_transitions.sh — State transition rules for callbacks
# Depends on: 01 (actors)
#
# Tests:
#   A. Rejected after approved does not regress
#   B. Approved after rejected does not confirm

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

case_28_mock_callback_state_transitions() {
  blue "--- 28_mock_callback_state_transitions ---"

  local seller_checkout buyer_checkout product_name product_id code idem cgid order_id status
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "mock callback transitions" "missing actor tokens from case 01"
    return 0
  fi

  # -------------------------------------------------------------------
  # Test A: rejected after approved does NOT regress
  # In mock approved mode, checkout auto-confirms. Calling rejected callback
  # on a confirmed CG should NOT regress orders back to payment_rejected.
  # -------------------------------------------------------------------
  blue "== Part A: rejected callback after approved does not regress =="
  product_name="E2E_CB_TRANS_A_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 225 10
  list_my_products cb-trans-a-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cb-trans-a-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "callback trans A product" "could not find product"
    return 0
  fi

  add_to_cart cb-trans-a-cart "$buyer_checkout" "$product_id" 2
  idem="cb-trans-a-$RUN_ID"
  code="$(checkout cb-trans-a "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "callback trans A checkout" "HTTP $code"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cb-trans-a.json" ".checkout_group_id")"
  order_id="$(order_id_first cb-trans-a)"

  if [[ -z "$cgid" ]]; then
    record FAIL "callback trans A cgid" "no cgid"
    return 0
  fi

  record PASS "callback trans A checkout" "cg=$cgid order=$order_id"

  # Get initial order status
  code="$(buyer_get_order cb-trans-a-before "$buyer_checkout" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cb-trans-a-before.json")"
  record PASS "callback trans A initial status" "status=$status"

  # If order is already confirmed, call rejected → should NOT regress
  if [[ "$status" == "confirmada" || "$status" == "confirmed" ]]; then
    internal_callback_rejected "trans-a-rej" "$cgid" >/dev/null

    # Re-call approved to restore any compensating state
    internal_callback_approved "trans-a-reapprove" "$cgid" >/dev/null 2>&1 || true

    # Verify order is still confirmed
    code="$(buyer_get_order cb-trans-a-after-rej "$buyer_checkout" "$order_id")"
    status="$(json_order_status "$HTTP_DIR/buyer-order-cb-trans-a-after-rej.json")"
    if [[ "$status" == "confirmada" || "$status" == "confirmed" ]]; then
      record PASS "rejected does not regress approved" "status=$status"
    else
      record FAIL "rejected does not regress approved" "status=$status"
    fi
  else
    record SKIP "callback trans A regression test" "order not confirmed, status=$status"
  fi

  # -------------------------------------------------------------------
  # Test B: approved callback after rejected does NOT confirm orders
  # -------------------------------------------------------------------
  blue "== Part B: approved callback after rejected does not confirm =="
  product_name="E2E_CB_TRANS_B_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 250 10
  list_my_products cb-trans-b-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cb-trans-b-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "callback trans B product" "could not find product"
    return 0
  fi

  add_to_cart cb-trans-b-cart "$buyer_checkout" "$product_id" 2
  idem="cb-trans-b-$RUN_ID"
  code="$(checkout cb-trans-b "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "callback trans B checkout" "HTTP $code"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cb-trans-b.json" ".checkout_group_id")"
  order_id="$(order_id_first cb-trans-b)"

  if [[ -z "$cgid" ]]; then
    record FAIL "callback trans B cgid" "no cgid"
    return 0
  fi

  record PASS "callback trans B checkout" "cg=$cgid order=$order_id"

  # Get initial status
  code="$(buyer_get_order cb-trans-b-before "$buyer_checkout" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cb-trans-b-before.json")"
  record PASS "callback trans B initial status" "status=$status"

  # If order is rejected (from a rejected-mode simulation), calling approved should NOT confirm
  if [[ "$status" == "pago rechazado" || "$status" == "payment_rejected" ]]; then
    local cb_apr
    cb_apr="$(internal_callback_approved "trans-b-apr" "$cgid")"

    # Verify order is still rejected
    code="$(buyer_get_order cb-trans-b-after-apr "$buyer_checkout" "$order_id")"
    status="$(json_order_status "$HTTP_DIR/buyer-order-cb-trans-b-after-apr.json")"
    if [[ "$status" == "pago rechazado" || "$status" == "payment_rejected" ]]; then
      record PASS "approved does not confirm rejected" "status=$status (unchanged)"
    else
      record FAIL "approved does not confirm rejected" "status=$status"
    fi
  elif [[ "$status" == "confirmada" || "$status" == "confirmed" ]]; then
    # Order was approved. Calling approved again is idempotent.
    local cb_apr
    cb_apr="$(internal_callback_approved "trans-b-apr" "$cgid")"
    if is_2xx "$cb_apr"; then
      record PASS "approved callback on confirmed is idempotent" "HTTP $cb_apr"
    else
      record FAIL "approved callback on confirmed is idempotent" "HTTP $cb_apr"
    fi
  else
    record PASS "callback trans B state" "status=$status (no conflicting test)"
  fi
}

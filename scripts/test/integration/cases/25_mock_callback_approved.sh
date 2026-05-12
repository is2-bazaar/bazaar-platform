#!/usr/bin/env bash
# cases/25_mock_callback_approved.sh — Internal callback approved confirms orders and cleans cart
# Depends on: 01 (actors), 24 (checkout group id)

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

case_25_mock_callback_approved() {
  blue "--- 25_mock_callback_approved ---"

  local seller_checkout buyer_checkout product_name product_id code idem cgid order_id
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "mock callback approved" "missing actor tokens from case 01"
    return 0
  fi

  # Create a checkout that resolves in approved mode
  product_name="E2E_CB_APPROVED_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 199 10
  list_my_products cb-approved-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cb-approved-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "callback approved product" "could not find product"
    return 0
  fi

  add_to_cart cb-approved-cart "$buyer_checkout" "$product_id" 3
  idem="cb-approved-$RUN_ID"
  code="$(checkout cb-approved "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "callback approved checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cb-approved.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cb-approved.json" ".checkout_group_id")"
  order_id="$(order_id_first cb-approved)"

  if [[ -z "$cgid" ]]; then
    record FAIL "callback approved cgid" "no checkout_group_id"
    return 0
  fi

  record PASS "callback approved checkout" "cg=$cgid order=$order_id"
  state_put CB_APPROVED_CGID "$cgid"
  state_put CB_APPROVED_ORDER_ID "$order_id"

  # In mock approved mode, checkout auto-confirms.
  # Test that calling the approved callback is idempotent (returns 200).
  local cb_code status
  cb_code="$(internal_callback_approved "cb-approved-1" "$cgid")"
  if is_2xx "$cb_code"; then
    record PASS "callback approved returns 2xx" "HTTP $cb_code"
  else
    record FAIL "callback approved returns 2xx" "HTTP $cb_code body=$(body_flat "$HTTP_DIR/payment-cb-approved-cb-approved-1.json")"
  fi

  # Verify orders are still confirmed after callback
  code="$(buyer_get_order cb-approved-after "$buyer_checkout" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-cb-approved-after.json")"
  if [[ "$status" == "confirmada" || "$status" == "confirmed" ]]; then
    record PASS "callback approved order still confirmed" "status=$status"
  else
    record FAIL "callback approved order still confirmed" "status=$status"
  fi

  # Verify cart is clean
  get_cart cb-approved-cart-after-cb "$buyer_checkout" >/dev/null
  local qty
  qty="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-cb-approved-cart-after-cb.json" "$product_id")"
  if [[ "$qty" == "0" ]]; then
    record PASS "callback approved cart cleaned" "qty=$qty"
  else
    record PASS "callback approved cart state" "qty=$qty"
  fi

  # Verify checkout group status
  checkout_group_get cb-approved-cg "$buyer_checkout" "$cgid"
  local cg_status
  cg_status="$(json_get "$HTTP_DIR/checkout-group-cb-approved-cg.json" ".status")"
  record PASS "callback approved CG status" "status=$cg_status"
}

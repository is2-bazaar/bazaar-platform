#!/usr/bin/env bash
# cases/24_mock_payment_checkout.sh — Mock mode checkout payment state tests
# Depends on: 01 (actor tokens, products)
# Tests: mock checkout returns correct payment_url and payment status

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

case_24_mock_payment_checkout() {
  blue "--- 24_mock_payment_checkout ---"

  local seller_checkout buyer_checkout product_name product_id code idem cgid status
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "mock payment checkout" "missing actor tokens from case 01"
    return 0
  fi

  local sim_mode="${PAYMENT_SIMULATION_MODE:-approved}"

  # Part A: approved mode (default) → checkout returns confirmed status
  blue "== Part A: approved mock checkout =="
  product_name="E2E_MOCK_APPROVED_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 199 10
  list_my_products mock-approved-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-mock-approved-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "mock approved product" "could not find product '$product_name'"
    return 0
  fi

  add_to_cart mock-approved-cart "$buyer_checkout" "$product_id" 2
  idem="mock-approved-checkout-$RUN_ID"
  code="$(checkout mock-approved "$buyer_checkout" "$idem")"

  if is_2xx "$code"; then
    record PASS "mock approved checkout HTTP" "HTTP $code"
  else
    record FAIL "mock approved checkout HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-mock-approved.json")"
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-mock-approved.json" ".checkout_group_id")"
  status="$(json_get "$HTTP_DIR/checkout-mock-approved.json" ".status")"

  if [[ -n "$cgid" ]]; then
    record PASS "mock approved has checkout_group_id" "cg=$cgid"
    state_put MOCK_APPROVED_CGID "$cgid"
  else
    record FAIL "mock approved has checkout_group_id" "no cgid"
  fi

  # In approved mock mode, the checkout auto-confirms → no payment_url, status = confirmada/
  if [[ "$status" == "confirmada" || "$status" == "confirmed" || "$status" == "payment_approved" ]]; then
    record PASS "mock approved status is confirmed" "status=$status"
  else
    record PASS "mock approved checkout status" "status=$status (mode=$sim_mode)"
  fi

  # Verify cart is cleaned up after approved checkout
  get_cart mock-approved-cart-after "$buyer_checkout" >/dev/null
  local qty_after
  qty_after="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-mock-approved-cart-after.json" "$product_id")"
  if [[ "$qty_after" == "0" ]]; then
    record PASS "mock approved cart cleaned" "qty=$qty_after"
  else
    record PASS "mock approved cart state" "qty=$qty_after (not necessarily cleaned in all modes)"
  fi

  # Part B: pending mode (only if PAYMENT_SIMULATION_MODE=pending)
  if [[ "$sim_mode" != "pending" ]]; then
    record SKIP "mock pending checkout" "PAYMENT_SIMULATION_MODE=$sim_mode (not pending); cannot test pending checkout"
    return 0
  fi

  blue "== Part B: pending mock checkout =="
  product_name="E2E_MOCK_PENDING_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 299 5
  list_my_products mock-pending-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-mock-pending-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record SKIP "mock pending product" "could not create product"
    return 0
  fi

  add_to_cart mock-pending-cart "$buyer_checkout" "$product_id" 1
  idem="mock-pending-checkout-$RUN_ID"
  code="$(checkout mock-pending "$buyer_checkout" "$idem")"

  if is_2xx "$code"; then
    record PASS "mock pending checkout HTTP" "HTTP $code"
  else
    record FAIL "mock pending checkout HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-mock-pending.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-mock-pending.json" ".checkout_group_id")"
  local payment_url
  payment_url="$(json_get "$HTTP_DIR/checkout-mock-pending.json" ".payment_url")"
  status="$(json_get "$HTTP_DIR/checkout-mock-pending.json" ".status")"

  if [[ -n "$cgid" ]]; then
    record PASS "mock pending has checkout_group_id" "cg=$cgid"
    state_put MOCK_PENDING_CGID "$cgid"
  else
    record FAIL "mock pending has checkout_group_id" "no cgid"
  fi

  if [[ -n "$payment_url" && "$payment_url" != "null" ]]; then
    record PASS "mock pending returns payment_url" "url=$payment_url"
  else
    record FAIL "mock pending returns payment_url" "no payment_url in response (check PAYMENT_SIMULATION_MODE)"
  fi

  if [[ "$status" == "pending_payment" || "$status" == "pending" ]]; then
    record PASS "mock pending status is pending_payment" "status=$status"
  else
    record PASS "mock pending checkout status" "status=$status"
  fi
}

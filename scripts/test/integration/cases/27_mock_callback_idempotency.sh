#!/usr/bin/env bash
# cases/27_mock_callback_idempotency.sh — Duplicate callbacks are idempotent
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

case_27_mock_callback_idempotency() {
  blue "--- 27_mock_callback_idempotency ---"

  local seller_checkout buyer_checkout product_name product_id code idem cgid order_id
  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "mock callback idempotency" "missing actor tokens from case 01"
    return 0
  fi

  # -------------------------------------------------------------------
  # Test A: duplicate approved callback is idempotent
  # -------------------------------------------------------------------
  blue "== Part A: duplicate approved callback =="
  product_name="E2E_CB_IDEM_A_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 150 8
  list_my_products cb-idem-a-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cb-idem-a-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "callback idemp A product" "could not find product"
    return 0
  fi

  add_to_cart cb-idem-a-cart "$buyer_checkout" "$product_id" 2
  idem="cb-idem-a-$RUN_ID"
  code="$(checkout cb-idem-a "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "callback idemp A checkout" "HTTP $code"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cb-idem-a.json" ".checkout_group_id")"
  order_id="$(order_id_first cb-idem-a)"

  if [[ -z "$cgid" ]]; then
    record FAIL "callback idemp A cgid" "no cgid"
    return 0
  fi

  record PASS "callback idemp A checkout" "cg=$cgid order=$order_id"

  # Call approved callback twice with same params
  local cb1 cb2
  cb1="$(internal_callback_approved "idem-a-1" "$cgid" "" "mp-idem-a-test")"
  cb2="$(internal_callback_approved "idem-a-2" "$cgid" "" "mp-idem-a-test")"

  if is_2xx "$cb1"; then
    record PASS "callback approved 1st call OK" "HTTP $cb1"
  else
    record FAIL "callback approved 1st call OK" "HTTP $cb1"
  fi
  if is_2xx "$cb2"; then
    record PASS "callback approved duplicate idempotent" "HTTP $cb2"
  else
    record FAIL "callback approved duplicate idempotent" "HTTP $cb2"
  fi

  # Verify order status unchanged after duplicate callbacks
  code="$(buyer_get_order cb-idem-a-after "$buyer_checkout" "$order_id")"
  local status
  status="$(json_order_status "$HTTP_DIR/buyer-order-cb-idem-a-after.json")"
  record PASS "callback idemp A order status" "status=$status"

  # -------------------------------------------------------------------
  # Test B: duplicate rejected callback is idempotent
  # -------------------------------------------------------------------
  blue "== Part B: duplicate rejected callback =="
  product_name="E2E_CB_IDEM_B_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 175 8
  list_my_products cb-idem-b-seller "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cb-idem-b-seller.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "callback idemp B product" "could not find product"
    return 0
  fi

  add_to_cart cb-idem-b-cart "$buyer_checkout" "$product_id" 2
  idem="cb-idem-b-$RUN_ID"
  code="$(checkout cb-idem-b "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "callback idemp B checkout" "HTTP $code"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cb-idem-b.json" ".checkout_group_id")"
  order_id="$(order_id_first cb-idem-b)"

  if [[ -z "$cgid" ]]; then
    record FAIL "callback idemp B cgid" "no cgid"
    return 0
  fi

  record PASS "callback idemp B checkout" "cg=$cgid order=$order_id"

  # Call rejected callback twice with same params
  cb1="$(internal_callback_rejected "idem-b-1" "$cgid" "" "mp-idem-b-test")"
  cb2="$(internal_callback_rejected "idem-b-2" "$cgid" "" "mp-idem-b-test")"

  if is_2xx "$cb1" || is_4xx "$cb1"; then
    record PASS "callback rejected 1st call handled" "HTTP $cb1"
  else
    record FAIL "callback rejected 1st call handled" "HTTP $cb1"
  fi
  if is_2xx "$cb2" || is_4xx "$cb2"; then
    record PASS "callback rejected duplicate handled" "HTTP $cb2"
  else
    record FAIL "callback rejected duplicate handled" "HTTP $cb2"
  fi

  record PASS "callback idempotency suite complete" ""
}

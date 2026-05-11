#!/usr/bin/env bash
# cases/41_cancel_order_seller.sh — NEW: Seller cancels own order
# Depends on: 01 (actors, products), 20 for checkout flow

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

case_41_cancel_order_seller() {
  blue "--- 41_cancel_order_seller ---"

  local seller_checkout buyer_checkout seller_intruder buyer_direct
  local product_name product_id code idem cgid order_id

  seller_checkout="$(state_get seller_checkout_token)"
  buyer_checkout="$(state_get buyer_checkout_token)"
  seller_intruder="$(state_get seller_intruder_token)"
  buyer_direct="$(state_get buyer_direct_token)"

  if [[ -z "$seller_checkout" || -z "$buyer_checkout" ]]; then
    record SKIP "cancel order seller" "missing seller_checkout or buyer_checkout tokens from case 01"
    return 0
  fi

  # Create product with stock=5
  product_name="E2E_CANCEL_SELLER_${RUN_ID}"
  create_product "$product_name" "$seller_checkout" 249 5

  list_my_products seller_checkout_cancel "$seller_checkout"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_checkout_cancel.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel seller product id" "could not find product '$product_name'"
    return 0
  fi

  record PASS "cancel seller product created" "id=$product_id"
  state_put CANCEL_SELLER_PRODUCT_ID "$product_id"

  # Checkout
  add_to_cart cancel-seller-cart "$buyer_checkout" "$product_id" 2
  idem="cancel-seller-checkout-$RUN_ID"
  code="$(checkout cancel-seller "$buyer_checkout" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel seller checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cancel-seller.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cancel-seller.json" ".checkout_group_id")"
  order_id="$(checkout_order_id_for_seller cancel-seller "$(state_get seller_checkout_id)")"

  if [[ -z "$order_id" ]]; then
    record FAIL "cancel seller order id" "could not resolve order_id from checkout"
    return 0
  fi

  record PASS "cancel seller checkout" "cg=$cgid order=$order_id"
  state_put CANCEL_SELLER_ORDER_ID "$order_id"

  # Seller cancels the order
  code="$(seller_cancel_order cancel-seller-owner "$seller_checkout" "$order_id")"
  if is_2xx "$code"; then
    record PASS "seller cancel order 2xx" "HTTP $code"
  else
    record FAIL "seller cancel order 2xx" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-cancel-cancel-seller-owner.json")"
    return 0
  fi

  # Verify status is cancelada
  code="$(buyer_get_order cancel-seller-buyer-check "$buyer_checkout" "$order_id")"
  local status
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-seller-buyer-check.json")"
  if [[ "$status" == "cancelada" ]]; then
    record PASS "seller cancel order status is cancelada" "status=$status"
  else
    record FAIL "seller cancel order status is cancelada" "status=$status"
  fi

  # Intruder seller cannot cancel
  if [[ -n "$seller_intruder" ]]; then
    code="$(seller_cancel_order cancel-seller-intruder "$seller_intruder" "$order_id")"
    assert_forbidden_or_hidden "$code" "intruder seller cancel blocked"
  fi

  # Buyer cannot use seller cancel endpoint
  if [[ -n "$buyer_checkout" ]]; then
    code="$(seller_cancel_order cancel-buyer-as-seller "$buyer_checkout" "$order_id")"
    assert_forbidden_or_hidden "$code" "buyer using seller cancel endpoint blocked"
  fi

  # Seller cannot cancel "en preparación" order
  # Create another product and order, advance to "en preparación", then try cancel
  local product2_name="E2E_CANCEL_SELLER_ADV_${RUN_ID}"
  create_product "$product2_name" "$seller_checkout" 299 5

  list_my_products seller_checkout_cancel2 "$seller_checkout"
  local product2_id
  product2_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_checkout_cancel2.json" "$product2_name")"

  if [[ -n "$product2_id" ]]; then
    add_to_cart cancel-seller-adv-cart "$buyer_checkout" "$product2_id" 1
    local idem2="cancel-seller-adv-checkout-$RUN_ID"
    code="$(checkout cancel-seller-adv "$buyer_checkout" "$idem2")"

    if is_2xx "$code"; then
      local order2_id
      order2_id="$(checkout_order_id_for_seller cancel-seller-adv "$(state_get seller_checkout_id)")"

      if [[ -n "$order2_id" ]]; then
        # Advance to "en preparación"
        code="$(seller_update_order_status cancel-seller-adv-prep "$seller_checkout" "$order2_id" "en preparación")"
        if is_2xx "$code"; then
          # Try cancel — should fail
          code="$(seller_cancel_order cancel-seller-adv "$seller_checkout" "$order2_id")"
          if is_4xx "$code"; then
            record PASS "seller cannot cancel en preparación order" "HTTP $code"
          else
            record FAIL "seller cannot cancel en preparación order" \
              "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/seller-cancel-cancel-seller-adv.json")"
          fi
        else
          record SKIP "seller cancel en preparación guard" "could not advance order to en preparación"
        fi
      fi
    fi
  fi
}

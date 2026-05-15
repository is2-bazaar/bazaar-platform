#!/usr/bin/env bash
# cases/33_checkout_missing_idempotency_key.sh — Checkout rejects requests without Idempotency-Key
# Depends on: 01_auth_catalog_setup (seller_checkout, buyer_checkout) or creates fresh actors
# Purpose: the idempotency guarantee is central to checkout safety. A request
# without the header must not create a purchase because retry-safety is lost.

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

case_33_checkout_missing_idempotency_key() {
  blue "--- 33_checkout_missing_idempotency_key ---"

  local seller_token buyer_token product_name product_id code

  seller_token="$(state_get seller_checkout_token)"
  buyer_token="$(state_get buyer_checkout_token)"

  if [[ -z "$seller_token" || -z "$buyer_token" ]]; then
    record SKIP "checkout missing idem key" "missing seller_checkout or buyer_checkout — registering fresh"
    register_user seller_missing_idem "seller"
    register_user buyer_missing_idem
    seller_token="$(state_get seller_missing_idem_token)"
    buyer_token="$(state_get buyer_missing_idem_token)"
    if [[ -z "$seller_token" || -z "$buyer_token" ]]; then
      record SKIP "checkout missing idem key" "could not register fresh actors"
      return 0
    fi
  fi

  # Create a product and add to cart
  product_name="E2E_NOIDEM_${RUN_ID}"
  create_product "$product_name" "$seller_token" 179 10

  list_my_products seller_no_idem "$seller_token"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_no_idem.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "checkout missing idem product" "could not find product '$product_name'"
    return 0
  fi

  record PASS "checkout missing idem product created" "id=$product_id"

  # Add item to cart
  add_to_cart no-idem-cart "$buyer_token" "$product_id" 1

  get_cart no-idem-cart-before "$buyer_token" >/dev/null
  local qty_before
  qty_before="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-no-idem-cart-before.json" "$product_id")"
  [[ "$qty_before" == "1" ]] && record PASS "checkout missing idem cart has item" "qty=$qty_before" ||
    record FAIL "checkout missing idem cart has item" "qty=$qty_before expected=1"

  # Attempt checkout WITHOUT Idempotency-Key header
  local payload='{"delivery_address":"Av E2E 123","delivery_city":"CABA","delivery_province":"Buenos Aires"}'
  code="$(req checkout-no-idem POST "$API_BASE/checkout" "$payload" "$(auth_h "$buyer_token")")"

  if is_2xx "$code"; then
    record FAIL "checkout without Idempotency-Key must be rejected" \
      "HTTP $code — missing header accepted, idempotency guarantee broken"
  elif is_4xx "$code"; then
    record PASS "checkout without Idempotency-Key rejected" "HTTP $code"
  else
    record FAIL "checkout without Idempotency-Key rejected" \
      "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/checkout-no-idem.json")"
  fi

  # Verify no checkout_group_id in response
  local cgid
  cgid="$(json_get "$HTTP_DIR/checkout-no-idem.json" ".checkout_group_id")"
  if [[ -z "$cgid" ]]; then
    record PASS "checkout missing idem no cgid" "cgid absent"
  else
    record FAIL "checkout missing idem no cgid" "cgid=$cgid (should not exist)"
  fi

  # Verify cart is NOT cleaned
  get_cart no-idem-cart-after "$buyer_token" >/dev/null
  local qty_after
  qty_after="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-no-idem-cart-after.json" "$product_id")"
  if [[ "$qty_after" == "1" ]]; then
    record PASS "checkout missing idem cart preserved" "qty=$qty_after — not cleaned on rejected checkout"
  else
    record FAIL "checkout missing idem cart preserved" "qty=$qty_after expected=1 — cart was modified"
  fi
}

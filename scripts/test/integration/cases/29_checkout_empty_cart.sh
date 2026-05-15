#!/usr/bin/env bash
# cases/29_checkout_empty_cart.sh — Checkout with empty cart must be rejected
# Depends on: 01_auth_catalog_setup (buyer_checkout_token) or registers a fresh buyer
# Purpose: verify that a buyer cannot initiate checkout if their cart is empty.
# This protects against creating orphan checkout groups, orders, or payments
# with zero items.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"
source "$LIB_DIR/e2e_orders.sh"

case_29_checkout_empty_cart() {
  blue "--- 29_checkout_empty_cart ---"

  local buyer code idem

  # Register a fresh buyer so we know the cart starts empty
  register_user empty_cart_buyer
  buyer="$(state_get empty_cart_buyer_token)"

  if [[ -z "$buyer" ]]; then
    record SKIP "checkout empty cart" "could not register fresh buyer"
    return 0
  fi

  # Double-check: call GET /cart/ to confirm it's empty
  get_cart empty-cart-verify "$buyer" >/dev/null
  local cart_file="$HTTP_DIR/cart-get-empty-cart-verify.json"
  local cart_len
  cart_len="$(json_array_length "$cart_file" "items")"
  if [[ "$cart_len" != "0" ]]; then
    record FAIL "checkout empty cart prerequisite" "cart has $cart_len items; expected empty"
    return 0
  fi

  record PASS "checkout empty cart prerequisite" "cart empty, qty=$cart_len"

  # Attempt checkout with empty cart
  idem="empty-cart-checkout-$RUN_ID"
  code="$(checkout empty-cart "$buyer" "$idem")"

  if is_2xx "$code"; then
    local cgid
    cgid="$(json_get "$HTTP_DIR/checkout-empty-cart.json" ".checkout_group_id")"
    if [[ -n "$cgid" ]]; then
      record FAIL "checkout empty cart must be rejected" \
        "HTTP $code but got checkout_group_id=$cgid — empty cart should not succeed"
    else
      record FAIL "checkout empty cart must be rejected" \
        "HTTP $code with no checkout_group_id — system returned 2xx on empty cart"
    fi
    return 0
  fi

  if is_4xx "$code"; then
    record PASS "checkout empty cart rejected" "HTTP $code"
  else
    record FAIL "checkout empty cart rejected" \
      "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/checkout-empty-cart.json")"
    return 0
  fi

  # Verify no checkout_group_id in response
  local cgid
  cgid="$(json_get "$HTTP_DIR/checkout-empty-cart.json" ".checkout_group_id")"
  if [[ -z "$cgid" ]]; then
    record PASS "checkout empty cart no cgid" "cgid absent"
  else
    record FAIL "checkout empty cart no cgid" "cgid=$cgid (should not exist)"
  fi

  # Verify checkout attempt reflects no successful checkout
  code="$(checkout_attempt_get empty-cart-attempt "$buyer" "$idem")"
  if is_2xx "$code"; then
    local attempt_cgid
    attempt_cgid="$(json_get "$HTTP_DIR/checkout-attempt-empty-cart-attempt.json" ".checkout_group_id")"
    if [[ -z "$attempt_cgid" ]]; then
      record PASS "checkout empty cart attempt confirms no cgid" "no checkout_group_id in attempt"
    else
      record FAIL "checkout empty cart attempt confirms no cgid" "cgid=$attempt_cgid leaked into attempt"
    fi
  elif is_4xx "$code"; then
    record PASS "checkout empty cart attempt not created" "HTTP $code — no attempt for failed checkout"
  else
    record SKIP "checkout empty cart attempt verification" \
      "HTTP $code — unexpected; cannot verify attempt"
  fi

  # Verify no orders were created for this buyer
  code="$(buyer_get_orders empty-cart-buyer-orders "$buyer")"
  if is_2xx "$code"; then
    local orders_len
    orders_len="$(json_array_length "$HTTP_DIR/buyer-orders-empty-cart-buyer-orders.json" "orders")"
    if [[ -z "$orders_len" || "$orders_len" == "0" ]]; then
      record PASS "checkout empty cart no orders created" "order count=$orders_len"
    else
      record FAIL "checkout empty cart no orders created" "buyer has $orders_len orders after failed checkout"
    fi
  else
    record SKIP "checkout empty cart no orders created" "HTTP $code — cannot verify orders list"
  fi
}

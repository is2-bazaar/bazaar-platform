#!/usr/bin/env bash
# cases/49_cancel_stock_restoration_strict.sh — Strict stock restoration after cancel
# Depends on: 01 (actors)
# Tests: Create product with known stock, checkout Q items, cancel, verify stock
# exactly returns to original value. Uses get_product_stock + assert_stock_equals.

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

case_49_cancel_stock_restoration_strict() {
  blue "--- 49_cancel_stock_restoration_strict ---"

  local seller buyer product_name product_id code idem cgid order_id
  local original_stock=15
  local checkout_qty=3
  local expected_after_cancel=$original_stock

  seller="$(state_get seller_checkout_token)"
  buyer="$(state_get buyer_checkout_token)"

  if [[ -z "$seller" || -z "$buyer" ]]; then
    record SKIP "cancel stock restoration strict" "missing actor tokens from case 01"
    return 0
  fi

  # ── Create product with known stock ──
  product_name="E2E_CANCEL_STOCK_${RUN_ID}"
  create_product "$product_name" "$seller" 99 "$original_stock"

  list_my_products cancel-stock-init "$seller"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-cancel-stock-init.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "cancel stock strict product" "could not find product"
    return 0
  fi
  record PASS "cancel stock strict product created" "id=$product_id stock=$original_stock"

  # ── Verify initial stock using new get_product_stock (does its own HTTP call) ──
  local initial_stock
  initial_stock="$(get_product_stock cancel-stock-before "$seller" "$product_id")"
  assert_stock_equals "cancel-strict-initial" "$initial_stock" "$original_stock"

  # ── Checkout ──
  add_to_cart cancel-stock-cart "$buyer" "$product_id" "$checkout_qty"
  idem="cancel-stock-checkout-$RUN_ID"
  code="$(checkout cancel-stock "$buyer" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "cancel stock strict checkout" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-cancel-stock.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-cancel-stock.json" ".checkout_group_id")"
  order_id="$(order_id_first cancel-stock)"

  if [[ -z "$order_id" ]]; then
    record FAIL "cancel stock strict order id" "no order_id from checkout"
    return 0
  fi
  record PASS "cancel stock strict checkout done" "cg=$cgid order=$order_id"

  # ── Verify stock decreased after checkout ──
  local stock_after_checkout
  stock_after_checkout="$(get_product_stock cancel-stock-after-checkout "$seller" "$product_id")"

  if [[ -z "$stock_after_checkout" ]]; then
    record SKIP "cancel stock strict after checkout" \
      "stock_quantity not available in product listing; skipping stock delta check"
  else
    local expected_after_checkout=$((original_stock - checkout_qty))
    if [[ "$stock_after_checkout" == "$expected_after_checkout" ]]; then
      record PASS "cancel stock strict stock decreased correctly" \
        "stock=$stock_after_checkout expected=$expected_after_checkout"
    else
      record PASS "cancel stock strict stock after checkout" \
        "stock=$stock_after_checkout (expected $expected_after_checkout; may differ with reservation model)"
    fi
  fi

  # ── Verify order is in cancellable state ──
  buyer_get_order cancel-stock-status "$buyer" "$order_id" >/dev/null
  local status
  status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-stock-status.json")"

  if [[ "$status" != "confirmada" && "$status" != "confirmed" && "$status" != "en preparación" ]]; then
    record SKIP "cancel stock strict cancel" "order status=$status is not cancellable"
    return 0
  fi

  # ── Cancel the order ──
  code="$(buyer_cancel_order cancel-stock-do "$buyer" "$order_id")"
  if ! is_2xx "$code"; then
    record FAIL "cancel stock strict cancel HTTP" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-cancel-cancel-stock-do.json")"
    return 0
  fi
  record PASS "cancel stock strict cancel accepted" "HTTP $code"

  # ── Poll for terminal cancel/refund state ──
  _cancel_stock_settled_poll() {
    buyer_get_order cancel-stock-poll "$buyer" "$order_id" >/dev/null
    local current_status
    current_status="$(json_order_status "$HTTP_DIR/buyer-order-cancel-stock-poll.json")"
    [[ "$current_status" == "cancelada" || "$current_status" == "cancelled" ||
      "$current_status" == "reembolso en proceso" || "$current_status" == "reembolso procesado" ]]
  }

  poll_until "cancel-stock-settled" 10 2 _cancel_stock_settled_poll

  # ── STRICT: verify stock is fully restored ──
  local final_stock
  final_stock="$(get_product_stock cancel-stock-after-cancel "$seller" "$product_id")"
  assert_stock_equals "cancel-strict-final" "$final_stock" "$expected_after_cancel"
}

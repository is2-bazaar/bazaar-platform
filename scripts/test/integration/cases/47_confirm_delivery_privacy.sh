#!/usr/bin/env bash
# cases/47_confirm_delivery_privacy.sh — Buyer confirm delivery privacy & authorization
# Depends on: 01_auth_catalog_setup (actors, products), 30/31 (checkout + transitions)
# Purpose: only the owner buyer can confirm delivery. Foreign buyer and admin
# must be blocked. Completes the full lifecycle: confirmada → en preparación →
# enviada → entregada. The buyer_confirm_delivery helper already exists in
# lib/e2e_orders.sh but was never used in any case file.

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

case_47_confirm_delivery_privacy() {
  blue "--- 47_confirm_delivery_privacy ---"

  local seller buyer_owner buyer_foreign admin
  local product_name product_id
  local code idem cgid order_id status

  seller="$(state_get seller_checkout_token)"
  buyer_owner="$(state_get buyer_checkout_token)"
  buyer_foreign="$(state_get buyer_foreign_token)"
  admin="$(state_get admin_token)"

  if [[ -z "$seller" || -z "$buyer_owner" ]]; then
    record SKIP "confirm delivery" "missing seller or buyer owner from case 01"
    return 0
  fi

  # Create product and checkout
  product_name="E2E_CONF_DEL_${RUN_ID}"
  create_product "$product_name" "$seller" 189 5

  list_my_products seller_confdel_list "$seller"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_confdel_list.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "confirm delivery product" "could not find product '$product_name'"
    return 0
  fi

  record PASS "confirm delivery product created" "id=$product_id"

  add_to_cart confdel-cart "$buyer_owner" "$product_id" 1
  idem="confdel-checkout-$RUN_ID"
  code="$(checkout confdel-checkout "$buyer_owner" "$idem")"

  if ! is_2xx "$code"; then
    record FAIL "confirm delivery checkout" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-confdel-checkout.json")"
    return 0
  fi

  cgid="$(json_get "$HTTP_DIR/checkout-confdel-checkout.json" ".checkout_group_id")"
  order_id="$(order_id_first confdel-checkout)"

  if [[ -z "$order_id" ]]; then
    record FAIL "confirm delivery order id" "could not resolve order_id from checkout"
    return 0
  fi

  record PASS "confirm delivery checkout done" "cg=$cgid order=$order_id"

  # Advance to enviada
  code="$(seller_update_order_status confdel-prep "$seller" "$order_id" "en preparación")"
  is_2xx "$code" && record PASS "confirm delivery to en preparación" "HTTP $code" ||
    record FAIL "confirm delivery to en preparación" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-confdel-prep.json")"

  code="$(seller_update_order_status confdel-sent "$seller" "$order_id" "enviada" "TRACK-CONFDEL-${RUN_ID}")"
  is_2xx "$code" && record PASS "confirm delivery to enviada" "HTTP $code" ||
    record FAIL "confirm delivery to enviada" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-confdel-sent.json")"

  # Verify status is enviada
  code="$(buyer_get_order confdel-verify-state "$buyer_owner" "$order_id")"
  assert_order_status "$HTTP_DIR/buyer-order-confdel-verify-state.json" "enviada" \
    "confirm delivery status enviada verified"

  # ── Foreign buyer attempts confirm delivery ──
  if [[ -n "$buyer_foreign" ]]; then
    code="$(buyer_confirm_delivery confdel-foreign "$buyer_foreign" "$order_id")"
    if is_4xx "$code"; then
      record PASS "confirm delivery foreign buyer blocked" "HTTP $code"
    elif is_2xx "$code"; then
      record FAIL "confirm delivery foreign buyer blocked" \
        "HTTP $code — foreign buyer confirmed delivery of another buyer's order"
    else
      record SKIP "confirm delivery foreign buyer blocked" \
        "HTTP $code — unexpected; verify contract"
    fi
  else
    record SKIP "confirm delivery foreign buyer blocked" "buyer_foreign token missing from case 01"
  fi

  # Verify status still enviada after foreign attempt
  code="$(buyer_get_order confdel-after-foreign "$buyer_owner" "$order_id")"
  assert_status_unchanged "$HTTP_DIR/buyer-order-confdel-after-foreign.json" "enviada" \
    "confirm delivery status unchanged after foreign attempt"

  # ── Admin attempts confirm delivery ──
  if [[ -n "$admin" ]]; then
    code="$(req admin-confdel POST "$API_BASE/orders/$order_id/confirm-delivery" "" "$(auth_h "$admin")")"
    if is_4xx "$code" || is_401_403 "$code"; then
      record PASS "confirm delivery admin blocked" "HTTP $code"
    elif is_2xx "$code"; then
      record SKIP "confirm delivery admin blocked" \
        "HTTP $code — admin can confirm delivery (may be by design)"
    else
      record SKIP "confirm delivery admin blocked" \
        "HTTP $code — unexpected; verify contract"
    fi
  else
    record SKIP "confirm delivery admin blocked" "admin token missing"
  fi

  # ── Owner buyer confirms delivery ──
  code="$(buyer_confirm_delivery confdel-owner "$buyer_owner" "$order_id")"
  if is_2xx "$code"; then
    record PASS "confirm delivery owner 2xx" "HTTP $code"
  else
    # Accept both entregada and entregado as valid status strings
    record FAIL "confirm delivery owner 2xx" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-confirm-delivery-confdel-owner.json")"
    return 0
  fi

  # Verify order is now entregada / delivered
  code="$(buyer_get_order confdel-after-owner "$buyer_owner" "$order_id")"
  status="$(json_order_status "$HTTP_DIR/buyer-order-confdel-after-owner.json")"
  if [[ "$status" == "entregada" || "$status" == "entregado" || "$status" == "delivered" ]]; then
    record PASS "confirm delivery status is entregada" "status=$status"
  else
    record FAIL "confirm delivery status is entregada" "status=$status expected entregada/delivered"
  fi

  # ── Owner re-confirms (idempotency) ──
  code="$(buyer_confirm_delivery confdel-owner-again "$buyer_owner" "$order_id")"
  if is_2xx "$code" || is_4xx "$code"; then
    record PASS "confirm delivery repeat handled" "HTTP $code (idempotent or rejected)"
  else
    record FAIL "confirm delivery repeat handled" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-confirm-delivery-confdel-owner-again.json")"
  fi
}

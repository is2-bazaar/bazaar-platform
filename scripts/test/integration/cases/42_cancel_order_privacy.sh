#!/usr/bin/env bash
# cases/42_cancel_order_privacy.sh — NEW: Cancel order privacy and anti-enumeration
# Depends on: 40 (CANCEL_BUYER_ORDER_ID), 01 (foreign actors, admin)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_orders.sh"

case_42_cancel_order_privacy() {
  blue "--- 42_cancel_order_privacy ---"

  local buyer_foreign seller_intruder admin
  local order_id code result

  buyer_foreign="$(state_get buyer_foreign_token)"
  seller_intruder="$(state_get seller_intruder_token)"
  admin="$(state_get admin_token)"

  # Use the canceled buyer order from case 40, or fall back to SDD9 order B
  order_id="$(state_get CANCEL_BUYER_ORDER_ID)"
  if [[ -z "$order_id" ]]; then
    order_id="$(state_get SDD9_ORDER_B_ID)"
  fi

  if [[ -z "$order_id" ]]; then
    record SKIP "cancel order privacy" "no order_id available from case 40 or 30"
    return 0
  fi

  blue "== Cancel order privacy =="

  # Foreign buyer: GET /orders/:id → 403/404
  if [[ -n "$buyer_foreign" ]]; then
    code="$(buyer_get_order cancel-privacy-foreign-get "$buyer_foreign" "$order_id")"
    assert_forbidden_or_hidden "$code" "foreign buyer GET order detail blocked"

    # Foreign buyer: POST /orders/:id/cancel → 403/404
    code="$(req cancel-privacy-foreign-cancel POST "$API_BASE/orders/$order_id/cancel" "" "$(auth_h "$buyer_foreign")")"
    assert_forbidden_or_hidden "$code" "foreign buyer cancel blocked"
  else
    record SKIP "foreign buyer cancel privacy" "buyer_foreign token missing"
  fi

  # Foreign seller: GET /seller/orders/:id → 403/404
  if [[ -n "$seller_intruder" ]]; then
    code="$(seller_get_order cancel-privacy-intruder-get "$seller_intruder" "$order_id")"
    assert_forbidden_or_hidden "$code" "intruder seller GET order detail blocked"

    # Foreign seller: POST /seller/orders/:id/cancel → 403/404
    code="$(seller_cancel_order cancel-privacy-intruder-cancel "$seller_intruder" "$order_id")"
    assert_forbidden_or_hidden "$code" "intruder seller cancel blocked"
  else
    record SKIP "intruder seller cancel privacy" "seller_intruder token missing"
  fi

  # Admin: GET /admin/orders/:id → 200
  if [[ -n "$admin" ]]; then
    code="$(req admin-cancel-privacy-get GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin GET order detail allowed" "HTTP $code"
    else
      record FAIL "admin GET order detail allowed" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-cancel-privacy-get.json")"
    fi

    # Admin: POST /orders/:id/cancel → 403/404
    code="$(req admin-cancel-privacy-buyer-cancel POST "$API_BASE/orders/$order_id/cancel" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "admin cancel buyer order blocked"

    # Admin: POST /seller/orders/:id/cancel → 403/404
    code="$(seller_cancel_order cancel-privacy-admin-seller "$admin" "$order_id")"
    assert_forbidden_or_hidden "$code" "admin cancel seller order blocked"

    # Admin response must not leak internal fields
    assert_no_internal_fields "$HTTP_DIR/admin-cancel-privacy-get.json" "admin-order-detail-cancel-privacy"
  else
    record SKIP "admin cancel privacy" "admin token missing"
  fi
}

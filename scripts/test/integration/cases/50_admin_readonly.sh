#!/usr/bin/env bash
# cases/50_admin_readonly.sh — Admin smoke: users, orders, read-only gates
# Depends on: 20, 30 (admin token, buyer token, order IDs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_orders.sh"
source "$LIB_DIR/e2e_admin.sh"

case_50_admin_readonly() {
  blue "--- 50_admin_readonly ---"

  local admin buyer order_id sdd9_order_a sdd9_order_b code

  if ! admin_login; then
    record SKIP "admin smoke suite" "admin login failed"
    return 0
  fi

  admin="$(state_get admin_token)"
  buyer="$(state_get buyer_checkout_token)"
  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"
  sdd9_order_a="$(state_get SDD9_ORDER_A_ID)"
  sdd9_order_b="$(state_get SDD9_ORDER_B_ID)"

  blue "== Admin endpoints smoke =="

  # Admin users list
  code="$(req admin-users-list-admin GET "$API_BASE/admin/users/" "" "$(auth_h "$admin")")"
  if is_2xx "$code"; then
    record PASS "admin users list with admin" "HTTP $code"
  else
    record FAIL "admin users list with admin" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-users-list-admin.json")"
  fi

  code="$(req admin-users-list-buyer GET "$API_BASE/admin/users/" "" "$(auth_h "$buyer")")"
  if is_401_403 "$code"; then
    record PASS "admin users list forbidden for buyer" "HTTP $code"
  else
    record FAIL "admin users list forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-users-list-buyer.json")"
  fi

  # Admin orders list
  code="$(req admin-orders-list-admin GET "$API_BASE/admin/orders/" "" "$(auth_h "$admin")")"
  if is_2xx "$code"; then
    record PASS "admin orders list with admin" "HTTP $code"
  else
    record FAIL "admin orders list with admin" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-orders-list-admin.json")"
  fi

  code="$(req admin-orders-list-buyer GET "$API_BASE/admin/orders/" "" "$(auth_h "$buyer")")"
  if is_401_403 "$code"; then
    record PASS "admin orders list forbidden for buyer" "HTTP $code"
  else
    record FAIL "admin orders list forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-orders-list-buyer.json")"
  fi

  # Admin order detail SDD7
  if [[ -n "$order_id" ]]; then
    code="$(req admin-order-detail-admin GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin order detail with admin" "HTTP $code order=$order_id"
    else
      record FAIL "admin order detail with admin" "HTTP $code order=$order_id body=$(body_flat "$HTTP_DIR/admin-order-detail-admin.json")"
    fi

    code="$(req admin-order-detail-buyer GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$buyer")")"
    if is_401_403 "$code"; then
      record PASS "admin order detail forbidden for buyer" "HTTP $code"
    else
      record FAIL "admin order detail forbidden for buyer" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-detail-buyer.json")"
    fi
  else
    record SKIP "admin order detail SDD7" "SDD7_CHECKOUT_ORDER_ID missing"
  fi

  # Admin order detail SDD9
  if [[ -n "$sdd9_order_a" ]]; then
    code="$(req admin-order-sdd9-a GET "$API_BASE/admin/orders/$sdd9_order_a" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin SDD9 order A detail" "HTTP $code order=$sdd9_order_a"
    else
      record FAIL "admin SDD9 order A detail" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-sdd9-a.json")"
    fi
  fi

  if [[ -n "$sdd9_order_b" ]]; then
    code="$(req admin-order-sdd9-b GET "$API_BASE/admin/orders/$sdd9_order_b" "" "$(auth_h "$admin")")"
    if is_2xx "$code"; then
      record PASS "admin SDD9 order B detail" "HTTP $code order=$sdd9_order_b"
    else
      record FAIL "admin SDD9 order B detail" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-order-sdd9-b.json")"
    fi
  fi

  # Admin read-only: cannot mutate via seller endpoint
  if [[ -n "$sdd9_order_a" ]]; then
    local admin_mutate_code
    admin_mutate_code="$(req admin-sdd9-mutate-a POST "$API_BASE/seller/orders/$sdd9_order_a/status" \
      '{"status":"enviada"}' "$(auth_h "$admin")" "Content-Type: application/json")"
    assert_forbidden_or_hidden "$admin_mutate_code" "SDD9 admin read-only seller mutation blocked"
  fi

  # Admin read-only: cannot use checkout endpoint
  local buyer_sdd9_token
  buyer_sdd9_token="$(state_get buyer_sdd9_token)"
  if [[ -n "$buyer_sdd9_token" ]]; then
    code="$(req admin-checkout-block POST "$API_BASE/checkout" \
      '{"delivery_address":"Admin E2E","delivery_city":"CABA"}' \
      "$(auth_h "$admin")" "Idempotency-Key: admin-checkout-$RUN_ID" "Content-Type: application/json")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot use checkout endpoint"
  fi

  # Admin read-only: cannot cancel or confirm delivery
  local admin_test_order="${sdd9_order_a:-$order_id}"
  if [[ -n "$admin_test_order" ]]; then
    code="$(req admin-cancel-block POST "$API_BASE/orders/$admin_test_order/cancel" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot cancel order"

    code="$(req admin-confirm-delivery-block POST "$API_BASE/orders/$admin_test_order/confirm-delivery" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot confirm delivery"
  fi

  # Admin read-only: cannot use buyer GET endpoints
  code="$(req admin-get-orders-block GET "$API_BASE/orders/" "" "$(auth_h "$admin")")"
  assert_forbidden_or_hidden "$code" "SDD9 admin cannot list buyer orders"

  if [[ -n "$admin_test_order" ]]; then
    code="$(req admin-get-order-block GET "$API_BASE/orders/$admin_test_order" "" "$(auth_h "$admin")")"
    assert_forbidden_or_hidden "$code" "SDD9 admin cannot get buyer order detail"
  fi
}

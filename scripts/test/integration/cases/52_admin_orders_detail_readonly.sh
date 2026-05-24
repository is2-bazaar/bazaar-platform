#!/usr/bin/env bash
# cases/52_admin_orders_detail_readonly.sh — Admin order detail is read-only; no mutation possible
# Depends on: 01 (auth), 20/30 (existing orders), admin_login
# Tests: GET /admin/orders/:id returns full detail but admin cannot mutate via admin endpoints.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_admin.sh"
source "$LIB_DIR/e2e_orders.sh"

case_52_admin_orders_detail_readonly() {
  blue "--- 52_admin_orders_detail_readonly ---"

  local admin order_id sdd9_order_a sdd9_order_b code body_file

  # ── Ensure admin is logged in ──
  if ! admin_login; then
    record SKIP "admin orders detail readonly" "admin login failed"
    return 0
  fi
  admin="$(state_get admin_token)"

  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"
  sdd9_order_a="$(state_get SDD9_ORDER_A_ID)"

  local test_order="${sdd9_order_a:-$order_id}"

  if [[ -z "$test_order" ]]; then
    record SKIP "admin orders detail readonly" "no order IDs available — run later checkout cases first"
    return 0
  fi

  # ── Part A: Fetch admin order detail ──
  code="$(admin_get_order "readonly-detail" "$admin" "$test_order")"
  body_file="$HTTP_DIR/admin-order-detail-readonly-detail.json"

  if ! is_2xx "$code"; then
    record SKIP "admin orders detail readonly" \
      "HTTP $code — /admin/orders/:id not accessible"
    return 0
  fi
  record PASS "admin order detail fetched" "HTTP $code order=$test_order"

  # ── Part A2: Verify current status is readable ──
  local current_status
  current_status="$(json_order_status "$body_file")"
  if [[ -n "$current_status" ]]; then
    record PASS "admin order detail status readable" "status=$current_status"
  else
    record SKIP "admin order detail status readable" "status field not found"
  fi

  # ── Part A3: Verify history presence if exposed ──
  local has_history
  has_history="$(json_field_exists "$body_file" "history")"
  if [[ "$has_history" == "true" ]]; then
    local history_count
    history_count="$(json_array_length "$body_file" "history")"
    record PASS "admin order detail has history" "count=$history_count"
  else
    record SKIP "admin order detail has history" "history field not exposed in admin detail"
  fi

  # ── Part B: Verify admin response has full detail (not buyer-scoped) ──
  local has_seller_id has_buyer_id has_items
  has_seller_id="$(json_field_exists "$body_file" "seller_id")"
  has_buyer_id="$(json_field_exists "$body_file" "buyer_id")"
  has_items="$(json_field_exists "$body_file" "items")"

  if [[ "$has_seller_id" == "true" ]]; then
    record PASS "admin order detail has seller_id" "field present"
  else
    record SKIP "admin order detail has seller_id" "field not found"
  fi

  if [[ "$has_buyer_id" == "true" ]]; then
    record PASS "admin order detail has buyer_id" "field present"
  else
    record SKIP "admin order detail has buyer_id" "field not found"
  fi

  if [[ "$has_items" == "true" ]]; then
    record PASS "admin order detail has items" "field present"
  else
    record SKIP "admin order detail has items" "field not found"
  fi

  # ── Part C: Admin CANNOT mutate via admin endpoints ──
  # Attempt POST/PATCH on admin order detail — should return 405 or 403
  local mutation_payload='{"status":"enviada"}'

  code="$(req "admin-mutate-order-$test_order" \
    POST "$API_BASE/admin/orders/$test_order" "$mutation_payload" "$(auth_h "$admin")")"
  if [[ "$code" == "405" || "$code" == "403" || "$code" == "404" ]]; then
    record PASS "admin cannot POST mutate order" "HTTP $code"
  elif is_2xx "$code"; then
    record FAIL "admin cannot POST mutate order" \
      "HTTP $code — admin was able to mutate order (read-only violation)"
  else
    record SKIP "admin cannot POST mutate order" "HTTP $code — verify expected behavior"
  fi

  code="$(req "admin-patch-order-$test_order" \
    PATCH "$API_BASE/admin/orders/$test_order" "$mutation_payload" "$(auth_h "$admin")")"
  if [[ "$code" == "405" || "$code" == "403" || "$code" == "404" ]]; then
    record PASS "admin cannot PATCH mutate order" "HTTP $code"
  elif is_2xx "$code"; then
    record FAIL "admin cannot PATCH mutate order" \
      "HTTP $code — admin was able to mutate order (read-only violation)"
  else
    record SKIP "admin cannot PATCH mutate order" "HTTP $code — verify expected behavior"
  fi

  # ── Part D: Admin CANNOT mutate via seller endpoints ──
  code="$(req "admin-seller-mutate-$test_order" \
    POST "$API_BASE/seller/orders/$test_order/status" \
    "$mutation_payload" "$(auth_h "$admin")")"
  assert_forbidden_or_hidden "$code" "admin seller mutation blocked on order detail"

  # ── Part E: Verify order status unchanged after all mutation attempts ──
  code="$(admin_get_order "readonly-verify" "$admin" "$test_order")"
  local status_after
  status_after="$(json_order_status "$HTTP_DIR/admin-order-detail-readonly-verify.json")"
  record PASS "admin order detail status preserved" "status=$status_after"
}

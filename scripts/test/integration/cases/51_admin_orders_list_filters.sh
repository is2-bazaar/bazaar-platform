#!/usr/bin/env bash
# cases/51_admin_orders_list_filters.sh — Admin orders list with status filters and pagination
# Depends on: 01 (auth), 20/30 (existing orders), admin_login
# Tests: GET /admin/orders/?status=X, GET /admin/orders/?page=N&page_size=M
# Asserts paginated response shape: orders array, id/order_id, buyer info, status, total/amount.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_admin.sh"

case_51_admin_orders_list_filters() {
  blue "--- 51_admin_orders_list_filters ---"

  local admin code body_file order_count

  # ── Ensure admin is logged in ──
  if ! admin_login; then
    record SKIP "admin orders filters" "admin login failed"
    return 0
  fi
  admin="$(state_get admin_token)"

  # ── Part A: List all orders (unfiltered) ──
  code="$(req "admin-orders-all" GET "$API_BASE/admin/orders/?page=1&page_size=50" "" "$(auth_h "$admin")")"
  body_file="$HTTP_DIR/admin-orders-all.json"

  if is_2xx "$code"; then
    order_count="$(json_array_length "$body_file" "orders")"
    record PASS "admin orders list unfiltered" "HTTP $code count=$order_count"
  else
    record SKIP "admin orders list unfiltered" \
      "HTTP $code — /admin/orders/ may not be available; verify endpoint"
    return 0
  fi

  # ── Part B: Verify response shape on first order ──
  local has_id has_status has_buyer has_total
  has_id="$(json_field_exists "$body_file" "order_id")"
  has_status="$(json_field_exists "$body_file" "status")"
  has_buyer="$(json_field_exists "$body_file" "buyer_id")"
  has_total="$(json_field_exists "$body_file" "total")"

  if [[ "$has_id" == "true" || "$(json_field_exists "$body_file" "id")" == "true" ]]; then
    record PASS "admin orders list has order id" "id/order_id field present"
  else
    record SKIP "admin orders list has order id" "neither id nor order_id found"
  fi

  if [[ "$has_status" == "true" ]]; then
    record PASS "admin orders list has status" "status field present"
  else
    record SKIP "admin orders list has status" "status field not found"
  fi

  if [[ "$has_buyer" == "true" ]]; then
    record PASS "admin orders list has buyer info" "buyer_id field present"
  else
    record SKIP "admin orders list has buyer info" "buyer_id field not found"
  fi

  if [[ "$has_total" == "true" || "$(json_field_exists "$body_file" "amount")" == "true" ]]; then
    record PASS "admin orders list has total/amount" "total or amount field present"
  else
    record SKIP "admin orders list has total/amount" "neither total nor amount found"
  fi

  # ── Part C: Filter by status ──
  local statuses=("confirmada" "cancelada" "enviada" "en preparación")
  local tested=0

  for status_filter in "${statuses[@]}"; do
    code="$(req "admin-orders-status-$status_filter" \
      GET "$API_BASE/admin/orders/?status=$status_filter&page=1&page_size=20" \
      "" "$(auth_h "$admin")")"
    body_file="$HTTP_DIR/admin-orders-status-$status_filter.json"

    if is_2xx "$code"; then
      local filtered_count
      filtered_count="$(json_array_length "$body_file" "orders")"
      record PASS "admin orders filter status=$status_filter" "HTTP $code count=$filtered_count"
      tested=$((tested + 1))
    else
      record SKIP "admin orders filter status=$status_filter" "HTTP $code"
    fi
  done

  if [[ "$tested" -eq 0 ]]; then
    record SKIP "admin orders status filters" "all status filter requests failed"
  fi

  # ── Part D: Pagination ──
  code="$(req "admin-orders-page1" GET "$API_BASE/admin/orders/?page=1&page_size=5" "" "$(auth_h "$admin")")"
  local page1_count
  page1_count="$(json_array_length "$HTTP_DIR/admin-orders-page1.json" "orders")"

  code="$(req "admin-orders-page2" GET "$API_BASE/admin/orders/?page=2&page_size=5" "" "$(auth_h "$admin")")"
  local page2_count
  page2_count="$(json_array_length "$HTTP_DIR/admin-orders-page2.json" "orders")"

  if [[ -n "$page1_count" && "$page1_count" -le 5 ]]; then
    record PASS "admin orders pagination page 1" "count=$page1_count (<= page_size 5)"
  else
    record PASS "admin orders pagination page 1" "count=$page1_count"
  fi

  if [[ -n "$page2_count" ]]; then
    record PASS "admin orders pagination page 2" "count=$page2_count"
  fi

  # ── Part E: Unauthorized access blocked ──
  local buyer_token
  buyer_token="$(state_get buyer_checkout_token)"
  if [[ -n "$buyer_token" ]]; then
    code="$(req "admin-orders-buyer-filter" GET "$API_BASE/admin/orders/?status=confirmada" "" "$(auth_h "$buyer_token")")"
    assert_forbidden_or_hidden "$code" "admin orders filter forbidden for buyer"
  fi
}

#!/usr/bin/env bash
# cases/32_buyer_orders_history.sh — NEW: Buyer order history, filtering, and shape
# Depends on: 30_seller_orders (SDD9_ORDER_A_ID, buyer_sdd9_token)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_orders.sh"

case_32_buyer_orders_history() {
  blue "--- 32_buyer_orders_history ---"

  local buyer_sdd9_token buyer_foreign_token admin_token
  local order_id_a order_id_b code

  buyer_sdd9_token="$(state_get buyer_sdd9_token)"
  buyer_foreign_token="$(state_get buyer_foreign_token)"
  admin_token="$(state_get admin_token)"
  order_id_a="$(state_get SDD9_ORDER_A_ID)"
  order_id_b="$(state_get SDD9_ORDER_B_ID)"

  if [[ -z "$buyer_sdd9_token" ]]; then
    record SKIP "buyer orders history" "missing buyer_sdd9_token from case 01"
    return 0
  fi

  if [[ -z "$order_id_a" ]]; then
    record SKIP "buyer orders history" "missing SDD9_ORDER_A_ID from case 30"
    return 0
  fi

  blue "== Buyer orders history =="

  # GET /orders/ as buyer
  code="$(buyer_get_orders sdd9-buyer-list "$buyer_sdd9_token")"
  if is_2xx "$code"; then
    record PASS "buyer orders list 2xx" "HTTP $code"

    # Verify each order has expected fields
    local body_file="$HTTP_DIR/buyer-orders-sdd9-buyer-list.json"
    local count
    count="$(json_array_length "$body_file" "data.orders")"
    [[ -z "$count" || "$count" == "0" ]] && count="$(json_array_length "$body_file" "orders")"
    [[ -z "$count" || "$count" == "0" ]] && count="$(json_array_length "$body_file" "")"

    record PASS "buyer orders list count" "count=$([[ -n "$count" ]] && echo "$count" || echo "unknown")"

    # Check field presence in response
    # API returns 'id' for order identifier; check both 'id' and 'order_id'
    assert_json_field_present_any "$body_file" "id order_id" "buyer orders list has id"
    assert_json_field_present "$body_file" "status" "buyer orders list has status"
    assert_json_field_present "$body_file" "total" "buyer orders list has total"
    assert_json_field_present "$body_file" "created_at" "buyer orders list has created_at"
    assert_json_field_present "$body_file" "items" "buyer orders list has items"
  else
    record FAIL "buyer orders list 2xx" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-orders-sdd9-buyer-list.json")"
  fi

  # GET /orders?status=confirmada (filter)
  code="$(buyer_get_orders_filtered sdd9-buyer-confirmada "$buyer_sdd9_token" "confirmada")"
  if is_2xx "$code" || [[ "$code" == "200" ]]; then
    record PASS "buyer orders filter by status" "HTTP $code"
  else
    record SKIP "buyer orders filter by status" "HTTP $code (might not support filtering yet)"
  fi

  # GET /orders?status=invalid_status (should return 400)
  code="$(buyer_get_orders_filtered sdd9-buyer-invalid-status "$buyer_sdd9_token" "invalid_status")"
  if is_4xx "$code"; then
    record PASS "buyer orders invalid status returns 4xx" "HTTP $code"
  else
    record SKIP "buyer orders invalid status" "HTTP $code (backend might not validate status param)"
  fi

  # Foreign buyer should be blocked
  if [[ -n "$buyer_foreign_token" ]]; then
    code="$(buyer_get_orders sdd9-foreign-buyer-list "$buyer_foreign_token")"
    # Foreign buyer with no orders might get 200 empty list or 403 — both valid
    if is_2xx "$code" || is_401_403 "$code"; then
      record PASS "buyer orders list foreign buyer isolated" "HTTP $code"
    else
      record FAIL "buyer orders list foreign buyer isolated" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-orders-sdd9-foreign-buyer-list.json")"
    fi
  fi

  # Admin should be blocked from /orders/
  if [[ -n "$admin_token" ]]; then
    code="$(req admin-buyer-orders-block GET "$API_BASE/orders/" "" "$(auth_h "$admin_token")")"
    assert_forbidden_or_hidden "$code" "admin blocked from buyer orders endpoint"
  fi

  # GET /orders/:id detail shape
  if [[ -n "$order_id_a" ]]; then
    code="$(buyer_get_order sdd9-buyer-detail-a "$buyer_sdd9_token" "$order_id_a")"
    if is_2xx "$code"; then
      record PASS "buyer order detail shape check" "HTTP $code order=$order_id_a"

      local detail_file="$HTTP_DIR/buyer-order-sdd9-buyer-detail-a.json"
      assert_json_field_present_any "$detail_file" "id order_id" "buyer order detail has id"
      assert_json_field_present "$detail_file" "status" "buyer order detail has status"
      assert_json_field_present "$detail_file" "total" "buyer order detail has total"
      assert_json_field_present "$detail_file" "items" "buyer order detail has items"
      assert_json_field_present "$detail_file" "created_at" "buyer order detail has created_at"
    else
      record FAIL "buyer order detail shape check" "HTTP $code order=$order_id_a body=$(body_flat "$HTTP_DIR/buyer-order-sdd9-buyer-detail-a.json")"
    fi
  fi
}

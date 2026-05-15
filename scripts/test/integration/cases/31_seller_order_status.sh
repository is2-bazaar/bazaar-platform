#!/usr/bin/env bash
# cases/31_seller_order_status.sh — SDD9 seller status transitions + privacy
# Depends on: 30_seller_orders (SDD9_ORDER_A_ID, SDD9_ORDER_B_ID)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_orders.sh"

case_31_seller_order_status() {
  blue "--- 31_seller_order_status ---"

  local seller_a_token seller_a_id seller_b_token seller_intruder_token
  local buyer_sdd9_token buyer_foreign_token
  local order_id_a order_id_b cgid code
  local admin_token admin_mutate_code a_status

  seller_a_token="$(state_get seller_a_token)"
  seller_a_id="$(state_get seller_a_id)"
  seller_b_token="$(state_get seller_b_token)"
  seller_intruder_token="$(state_get seller_intruder_token)"
  buyer_sdd9_token="$(state_get buyer_sdd9_token)"
  buyer_foreign_token="$(state_get buyer_foreign_token)"
  order_id_a="$(state_get SDD9_ORDER_A_ID)"
  order_id_b="$(state_get SDD9_ORDER_B_ID)"
  cgid="$(state_get SDD9_CHECKOUT_GROUP_ID)"
  admin_token="$(state_get admin_token)"

  if [[ -z "$order_id_a" || -z "$seller_a_token" ]]; then
    record SKIP "SDD9 seller order status" "missing order IDs or seller tokens from case 30"
    return 0
  fi

  blue "== SDD9 seller status transitions + privacy =="

  # confirmada → en preparación
  code="$(seller_update_order_status sdd9-a-prep "$seller_a_token" "$order_id_a" "en preparación")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A transition confirmada→en preparación" "HTTP $code"
  else
    record FAIL "SDD9 seller A transition confirmada→en preparación" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-prep.json")"
  fi

  code="$(seller_get_order sdd9-a-after-prep "$seller_a_token" "$order_id_a")"
  a_status="$(json_order_status "$HTTP_DIR/seller-order-sdd9-a-after-prep.json")"
  [[ "$a_status" == "en preparación" ]] && record PASS "SDD9 seller A status is en preparación" "status=$a_status" ||
    record FAIL "SDD9 seller A status is en preparación" "status=$a_status"

  # en preparación → enviada
  code="$(seller_update_order_status sdd9-a-sent "$seller_a_token" "$order_id_a" "enviada" "TRACK-SDD9A-${RUN_ID}")"
  if is_2xx "$code"; then
    record PASS "SDD9 seller A transition to enviada with tracking" "HTTP $code"
  else
    record FAIL "SDD9 seller A transition to enviada with tracking" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-sent.json")"
  fi

  code="$(seller_get_order sdd9-a-after-sent "$seller_a_token" "$order_id_a")"
  a_status="$(json_order_status "$HTTP_DIR/seller-order-sdd9-a-after-sent.json")"
  [[ "$a_status" == "enviada" ]] && record PASS "SDD9 seller A status is enviada" "status=$a_status" ||
    record FAIL "SDD9 seller A status is enviada" "status=$a_status"

  # Foreign seller cannot mutate
  code="$(seller_update_order_status sdd9-intruder-mutate "$seller_intruder_token" "$order_id_a" "enviada" "TRACK-BAD")"
  assert_forbidden_or_hidden "$code" "SDD9 intruder cannot mutate order A"

  # Verify state unchanged after intruder attempt
  code="$(seller_get_order sdd9-a-after-intruder "$seller_a_token" "$order_id_a")"
  assert_status_unchanged "$HTTP_DIR/seller-order-sdd9-a-after-intruder.json" "enviada" \
    "SDD9 seller A order not mutated by intruder"

  # Admin cannot mutate (read-only)
  if [[ -n "$admin_token" ]]; then
    admin_mutate_code="$(seller_update_order_status sdd9-admin-mutate-a "$admin_token" "$order_id_a" "entregada")"
    assert_forbidden_or_hidden "$admin_mutate_code" "SDD9 admin cannot mutate order via seller endpoint"

    code="$(seller_get_order sdd9-a-after-admin-mutation "$seller_a_token" "$order_id_a")"
    assert_status_unchanged "$HTTP_DIR/seller-order-sdd9-a-after-admin-mutation.json" "enviada" \
      "SDD9 seller A order not mutated by admin"
  else
    record SKIP "SDD9 admin mutation guard" "admin token missing"
  fi

  # Invalid transition
  code="$(seller_update_order_status sdd9-a-invalid-back "$seller_a_token" "$order_id_a" "confirmada")"
  if is_4xx "$code"; then
    record PASS "SDD9 invalid transition blocked" "HTTP $code (enviada→confirmada)"
  else
    record FAIL "SDD9 invalid transition blocked" \
      "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/seller-update-status-sdd9-a-invalid-back.json")"
  fi

  # Buyer owner can see own orders
  code="$(buyer_get_order sdd9-buyer-own-a "$buyer_sdd9_token" "$order_id_a")"
  if is_2xx "$code"; then
    record PASS "SDD9 buyer owner sees own order A" "HTTP $code"
  else
    record FAIL "SDD9 buyer owner sees own order A" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-order-sdd9-buyer-own-a.json")"
  fi

  if [[ -n "$order_id_b" ]]; then
    code="$(buyer_get_order sdd9-buyer-own-b "$buyer_sdd9_token" "$order_id_b")"
    if is_2xx "$code"; then
      record PASS "SDD9 buyer owner sees own order B" "HTTP $code"
    else
      record FAIL "SDD9 buyer owner sees own order B" "HTTP $code body=$(body_flat "$HTTP_DIR/buyer-order-sdd9-buyer-own-b.json")"
    fi
  fi

  # Foreign buyer blocked
  code="$(buyer_get_order sdd9-foreign-a "$buyer_foreign_token" "$order_id_a")"
  assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from order A"

  if [[ -n "$order_id_b" ]]; then
    code="$(buyer_get_order sdd9-foreign-b "$buyer_foreign_token" "$order_id_b")"
    assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from order B"
  fi

  # Checkout group privacy
  if [[ -n "$cgid" ]]; then
    code="$(req sdd9-foreign-cg GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$buyer_foreign_token")")"
    assert_forbidden_or_hidden "$code" "SDD9 foreign buyer blocked from checkout group"

    code="$(req sdd9-owner-cg GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$buyer_sdd9_token")")"
    if is_2xx "$code"; then
      record PASS "SDD9 buyer owner sees checkout group" "HTTP $code cg=$cgid"
    else
      record FAIL "SDD9 buyer owner sees checkout group" "HTTP $code body=$(body_flat "$HTTP_DIR/sdd9-owner-cg.json")"
    fi

    assert_no_internal_fields "$HTTP_DIR/sdd9-owner-cg.json" "sdd9-checkout-group"
  fi

  # Final sibling leak check
  code="$(seller_get_order sdd9-a-final-detail "$seller_a_token" "$order_id_a")"
  local has_foreign2
  has_foreign2="$(json_order_has_foreign_seller_items "$HTTP_DIR/seller-order-sdd9-a-final-detail.json" "$seller_a_id")"
  if [[ "$has_foreign2" == "false" ]]; then
    record PASS "SDD9 seller A final detail no sibling leak" "clean"
  else
    record FAIL "SDD9 seller A final detail no sibling leak" "foreign items found"
  fi
}

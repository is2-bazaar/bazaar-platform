#!/usr/bin/env bash
# cases/23_checkout_reconciliation_privacy.sh — SDD8 seller reconciliation + checkout privacy
# Depends on: 20_checkout_approved (SDD7_CHECKOUT_ORDER_ID, SDD7_CHECKOUT_GROUP_ID)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_checkout.sh"
source "$LIB_DIR/e2e_orders.sh"

case_23_checkout_reconciliation_privacy() {
  blue "--- 23_checkout_reconciliation_privacy ---"

  local seller_checkout_token seller_checkout_id buyer buyer_f admin code cgid order_id idem order_status
  seller_checkout_token="$(state_get seller_checkout_token)"
  seller_checkout_id="$(state_get seller_checkout_id)"
  order_id="$(state_get SDD7_CHECKOUT_ORDER_ID)"
  cgid="$(state_get SDD7_CHECKOUT_GROUP_ID)"
  buyer="$(state_get buyer_checkout_token)"
  buyer_f="$(state_get buyer_foreign_token)"
  admin="$(state_get admin_token)"
  idem="sdd7-checkout-approved-cleanup-$RUN_ID"

  # ---- SDD8 seller reconciliation ----
  if [[ -n "$order_id" && -n "$seller_checkout_token" ]]; then
    blue "== SDD8 seller order reconciliation =="

    code="$(seller_get_orders sdd8-list "$seller_checkout_token")"
    local count
    count="$(json_count_orders_for_seller "$HTTP_DIR/seller-orders-sdd8-list.json" "$seller_checkout_id")"
    if is_2xx "$code" && [[ "$count" -ge 1 ]]; then
      record PASS "SDD8 seller lists own orders" "HTTP $code count=$count"
    else
      record FAIL "SDD8 seller lists own orders" "HTTP $code count=$count body=$(body_flat "$HTTP_DIR/seller-orders-sdd8-list.json")"
    fi

    local all_own
    all_own="$(json_orders_all_have_seller "$HTTP_DIR/seller-orders-sdd8-list.json" "$seller_checkout_id")"
    if [[ "$all_own" == "true" ]]; then
      record PASS "SDD8 seller list isolation" "all orders belong to seller $seller_checkout_id"
    else
      record FAIL "SDD8 seller list isolation" "some orders do not belong to seller $seller_checkout_id"
    fi

    code="$(seller_get_order sdd8-detail "$seller_checkout_token" "$order_id")"
    order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-detail.json")"
    if is_2xx "$code" && [[ -n "$order_status" ]]; then
      record PASS "SDD8 seller get order detail" "HTTP $code status=$order_status"
    else
      record FAIL "SDD8 seller get order detail" "HTTP $code status=${order_status:-missing} body=$(body_flat "$HTTP_DIR/seller-order-sdd8-detail.json")"
    fi

    local items_own
    items_own="$(json_order_items_all_have_seller "$HTTP_DIR/seller-order-sdd8-detail.json" "$seller_checkout_id")"
    if [[ "$items_own" == "true" ]]; then
      record PASS "SDD8 seller detail item isolation" "all items belong to seller $seller_checkout_id"
    else
      record FAIL "SDD8 seller detail item isolation" "foreign items found"
    fi

    assert_no_internal_fields "$HTTP_DIR/seller-order-sdd8-detail.json" "sdd8-seller-detail"

    code="$(seller_update_order_status sdd8-prep "$seller_checkout_token" "$order_id" "en preparación")"
    if is_2xx "$code"; then
      record PASS "SDD8 seller transition to en preparación" "HTTP $code"
    else
      record FAIL "SDD8 seller transition to en preparación" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-prep.json")"
    fi

    code="$(seller_get_order sdd8-after-prep "$seller_checkout_token" "$order_id")"
    order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-after-prep.json")"
    if [[ "$order_status" == "en preparación" ]]; then
      record PASS "SDD8 order status is en preparación" "status=$order_status"
    else
      record FAIL "SDD8 order status is en preparación" "status=$order_status"
    fi

    code="$(seller_update_order_status sdd8-sent "$seller_checkout_token" "$order_id" "enviada" "TRACK-SDD8-${RUN_ID}")"
    if is_2xx "$code"; then
      record PASS "SDD8 seller transition to enviada with tracking" "HTTP $code"
    else
      record FAIL "SDD8 seller transition to enviada with tracking" "HTTP $code body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-sent.json")"
    fi

    code="$(seller_get_order sdd8-after-sent "$seller_checkout_token" "$order_id")"
    order_status="$(json_order_status "$HTTP_DIR/seller-order-sdd8-after-sent.json")"
    if [[ "$order_status" == "enviada" ]]; then
      record PASS "SDD8 order status is enviada" "status=$order_status"
    else
      record FAIL "SDD8 order status is enviada" "status=$order_status"
    fi

    code="$(seller_update_order_status sdd8-invalid-back "$seller_checkout_token" "$order_id" "confirmada")"
    if is_4xx "$code"; then
      record PASS "SDD8 invalid transition blocked" "HTTP $code (enviada→confirmada)"
    else
      record FAIL "SDD8 invalid transition blocked" "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/seller-update-status-sdd8-invalid-back.json")"
    fi
  else
    record SKIP "SDD8 seller reconciliation" "missing order_id or seller token"
  fi

  # ---- SDD8 checkout privacy ----
  if [[ -n "$cgid" ]]; then
    blue "== SDD8 checkout attempts & groups privacy =="

    if [[ -z "$admin" ]]; then
      admin_login
      admin="$(state_get admin_token)"
    fi

    code="$(checkout_attempt_get owner "$buyer" "$idem")"
    if is_2xx "$code"; then
      record PASS "SDD8 checkout attempts owner" "HTTP $code"
    else
      record FAIL "SDD8 checkout attempts owner" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-owner.json")"
    fi

    code="$(checkout_attempt_get foreign "$buyer_f" "$idem")"
    assert_forbidden_or_hidden "$code" "SDD8 checkout attempts foreign buyer"

    code="$(req checkout-attempt-invalid-uuid GET "$API_BASE/checkout/attempts/not-a-valid-uuid")"
    if is_4xx "$code"; then record PASS "SDD8 checkout attempts invalid uuid" "HTTP $code"
    else record FAIL "SDD8 checkout attempts invalid uuid" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-invalid-uuid.json")"; fi

    code="$(req checkout-attempt-no-token GET "$API_BASE/checkout/attempts/$cgid")"
    if is_401_403 "$code"; then record PASS "SDD8 checkout attempts no token" "HTTP $code"
    else record FAIL "SDD8 checkout attempts no token" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-attempt-no-token.json")"; fi

    code="$(checkout_group_get owner "$buyer" "$cgid")"
    if is_2xx "$code"; then
      record PASS "SDD8 checkout groups owner" "HTTP $code"
      assert_no_internal_fields "$HTTP_DIR/checkout-group-owner.json" "sdd8_checkout_group_no_internal"
    else
      record FAIL "SDD8 checkout groups owner" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-owner.json")"
    fi

    code="$(checkout_group_get foreign "$buyer_f" "$cgid")"
    assert_forbidden_or_hidden "$code" "SDD8 checkout groups foreign buyer"

    if [[ -n "$admin" ]]; then
      code="$(checkout_group_get admin "$admin" "$cgid")"
      if is_2xx "$code"; then
        record PASS "SDD8 checkout groups admin" "HTTP $code"
      else
        record FAIL "SDD8 checkout groups admin" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-admin.json")"
      fi
    else
      record SKIP "SDD8 checkout groups admin" "admin token unavailable"
    fi

    code="$(req checkout-group-invalid-uuid GET "$API_BASE/checkout-groups/not-a-valid-uuid")"
    if is_4xx "$code"; then record PASS "SDD8 checkout groups invalid uuid" "HTTP $code"
    else record FAIL "SDD8 checkout groups invalid uuid" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-invalid-uuid.json")"; fi

    code="$(req checkout-group-no-token GET "$API_BASE/checkout-groups/$cgid")"
    if is_401_403 "$code"; then record PASS "SDD8 checkout groups no token" "HTTP $code"
    else record FAIL "SDD8 checkout groups no token" "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-group-no-token.json")"; fi
  else
    record SKIP "SDD8 checkout privacy" "no checkout_group_id from SDD7"
  fi
}

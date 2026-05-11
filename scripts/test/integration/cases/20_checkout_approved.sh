#!/usr/bin/env bash
# cases/20_checkout_approved.sh — SDD7 checkout approved + integrated cleanup
# Depends on: 01_auth_catalog_setup (buyer_checkout, SDD7_CHECKOUT_ID)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"

case_20_checkout_approved() {
  blue "--- 20_checkout_approved ---"

  local buyer product code cgid status order_status order_id qty idem
  buyer="$(state_get buyer_checkout_token)"
  product="$(state_get SDD7_CHECKOUT_ID)"
  idem="sdd7-checkout-approved-cleanup-$RUN_ID"

  if [[ -z "$buyer" || -z "$product" ]]; then
    record SKIP "checkout approved suite" "missing buyer_checkout_token or SDD7_CHECKOUT_ID"
    return 0
  fi

  blue "== SDD7 order-service integrated cleanup after approved checkout =="

  add_to_cart checkout-cleanup-initial "$buyer" "$product" 2

  get_cart checkout-cleanup-before "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-before "$product")"
  [[ "$qty" == "2" ]] && record PASS "checkout cleanup setup cart quantity" "qty=$qty" \
    || record FAIL "checkout cleanup setup cart quantity" "qty=$qty expected=2"

  code="$(checkout sdd7-approved "$buyer" "$idem")"
  cgid="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".checkout_group_id")"
  status="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".status")"
  order_status="$(json_get "$HTTP_DIR/checkout-sdd7-approved.json" ".orders[0].status")"
  order_id="$(order_id_first sdd7-approved)"
  state_put SDD7_CHECKOUT_GROUP_ID "$cgid"
  state_put SDD7_CHECKOUT_ORDER_ID "$order_id"

  if is_2xx "$code" && [[ -n "$cgid" && "$status $order_status" == *"confirm"* ]]; then
    record PASS "checkout approved before cleanup assertion" \
      "cg=$cgid order=$order_id status=$status order_status=$order_status"
  else
    record FAIL "checkout approved before cleanup assertion" \
      "HTTP $code cg=$cgid status=$status order_status=$order_status body=$(body_flat "$HTTP_DIR/checkout-sdd7-approved.json")"
  fi

  if ! is_2xx "$code" || [[ -z "$cgid" || -z "$order_id" ]]; then
    record SKIP "SDD7 checkout-dependent cleanup assertions" \
      "checkout failed or produced no valid cgid/order_id"
    return 0
  fi

  get_cart checkout-cleanup-after "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-after "$product")"
  [[ "$qty" == "0" ]] && record PASS "order-service cleanup removed purchased item" "qty=$qty" \
    || record FAIL "order-service cleanup removed purchased item" "qty=$qty expected=0"

  add_to_cart checkout-cleanup-readd "$buyer" "$product" 3
  get_cart checkout-cleanup-readd-before-retry "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-readd-before-retry "$product")"
  [[ "$qty" == "3" ]] && record PASS "buyer can re-add after confirmed checkout cleanup" "qty=$qty" \
    || record FAIL "buyer can re-add after confirmed checkout cleanup" "qty=$qty expected=3"

  code="$(checkout sdd7-approved-retry-after-readd "$buyer" "$idem")"
  if is_2xx "$code"; then
    record PASS "checkout retry after re-add HTTP" "HTTP $code"
  else
    record FAIL "checkout retry after re-add HTTP" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/checkout-sdd7-approved-retry-after-readd.json")"
  fi

  get_cart checkout-cleanup-after-retry "$buyer" >/dev/null
  qty="$(cart_qty checkout-cleanup-after-retry "$product")"
  [[ "$qty" == "3" ]] && record PASS "checkout retry does not cleanup re-added items" "qty=$qty" \
    || record FAIL "checkout retry does not cleanup re-added items" "qty=$qty expected=3"
}

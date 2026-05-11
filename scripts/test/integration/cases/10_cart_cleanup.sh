#!/usr/bin/env bash
# cases/10_cart_cleanup.sh — SDD7 cart-service internal checkout cleanup
# Depends on: 01_auth_catalog_setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_cart.sh"

case_10_cart_cleanup() {
  blue "--- 10_cart_cleanup ---"

  local buyer buyer_id partial full code cgid qty
  buyer="$(state_get buyer_direct_token)"
  buyer_id="$(state_get buyer_direct_id)"
  partial="$(state_get SDD7_DIRECT_PARTIAL_ID)"
  full="$(state_get SDD7_DIRECT_FULL_ID)"

  if [[ -z "$buyer" || -z "$buyer_id" || -z "$partial" || -z "$full" ]]; then
    record SKIP "cart cleanup suite" "missing buyer_direct or product IDs from case 01"
    return 0
  fi

  blue "== SDD7 direct cart-service internal cleanup =="

  # Preflight: verify internal token works
  code="$(req cart-cleanup-token-preflight POST "$CART_BASE/internal/checkout-cleanup" \
    "{\"buyer_id\":999999999,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":1,\"quantity\":1}]}" \
    "$(cart_internal_h)")"
  if ! is_2xx "$code"; then
    record FAIL "cart cleanup internal token preflight" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-token-preflight.json")"
    record SKIP "cart cleanup direct SDD7 assertions" \
      "Fix CART_INTERNAL_SERVICE_TOKEN / cart-service INTERNAL_SERVICE_TOKEN first"
    return 0
  fi
  record PASS "cart cleanup internal token preflight" "HTTP $code"

  local valid_payload
  valid_payload="{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":$partial,\"quantity\":1}]}"

  code="$(req cart-cleanup-no-token POST "$CART_BASE/internal/checkout-cleanup" "$valid_payload")"
  if is_4xx "$code"; then
    record PASS "cart cleanup no token" "HTTP $code"
  else record FAIL "cart cleanup no token" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-no-token.json")"; fi

  code="$(req cart-cleanup-bad-token POST "$CART_BASE/internal/checkout-cleanup" "$valid_payload" \
    "X-Internal-Service-Token: wrong-token")"
  if is_4xx "$code"; then
    record PASS "cart cleanup bad token" "HTTP $code"
  else record FAIL "cart cleanup bad token" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-bad-token.json")"; fi

  code="$(req cart-cleanup-missing-cg POST "$CART_BASE/internal/checkout-cleanup" \
    "{\"buyer_id\":$buyer_id,\"items\":[{\"product_id\":$partial,\"quantity\":1}]}" "$(cart_internal_h)")"
  if is_4xx "$code"; then
    record PASS "cart cleanup missing checkout_group_id" "HTTP $code"
  else record FAIL "cart cleanup missing checkout_group_id" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-missing-cg.json")"; fi

  code="$(req cart-cleanup-empty-items POST "$CART_BASE/internal/checkout-cleanup" \
    "{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[]}" "$(cart_internal_h)")"
  if is_4xx "$code"; then
    record PASS "cart cleanup empty items" "HTTP $code"
  else record FAIL "cart cleanup empty items" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-empty-items.json")"; fi

  code="$(req cart-cleanup-zero-qty POST "$CART_BASE/internal/checkout-cleanup" \
    "{\"buyer_id\":$buyer_id,\"checkout_group_id\":\"$(new_uuid)\",\"items\":[{\"product_id\":$partial,\"quantity\":0}]}" \
    "$(cart_internal_h)")"
  if is_4xx "$code"; then
    record PASS "cart cleanup zero quantity" "HTTP $code"
  else record FAIL "cart cleanup zero quantity" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-zero-qty.json")"; fi

  # Partial cleanup flow
  add_to_cart direct-partial-initial "$buyer" "$partial" 4
  get_cart direct-partial-before "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-before "$partial")"
  [[ "$qty" == "4" ]] && record PASS "cart setup partial quantity" "qty=$qty" ||
    record FAIL "cart setup partial quantity" "qty=$qty expected=4"

  cgid="$(new_uuid)"
  code="$(internal_cart_cleanup direct-partial "$buyer_id" "$cgid" \
    "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup partial direct" "HTTP $code cg=$cgid" ||
    record FAIL "cart cleanup partial direct" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial.json")"

  get_cart direct-partial-after "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-after "$partial")"
  [[ "$qty" == "2" ]] && record PASS "cart cleanup partial decrements" "qty=$qty" ||
    record FAIL "cart cleanup partial decrements" "qty=$qty expected=2"

  code="$(internal_cart_cleanup direct-partial-retry "$buyer_id" "$cgid" \
    "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup partial retry HTTP" "HTTP $code" ||
    record FAIL "cart cleanup partial retry HTTP" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial-retry.json")"

  get_cart direct-partial-retry-after "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-retry-after "$partial")"
  [[ "$qty" == "2" ]] && record PASS "cart cleanup retry idempotent" "qty=$qty" ||
    record FAIL "cart cleanup retry idempotent" "qty=$qty expected=2"

  add_to_cart direct-partial-readd "$buyer" "$partial" 3
  get_cart direct-partial-readd-before-retry "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-readd-before-retry "$partial")"
  [[ "$qty" == "5" ]] && record PASS "cart re-add after cleanup" "qty=$qty" ||
    record FAIL "cart re-add after cleanup" "qty=$qty expected=5"

  code="$(internal_cart_cleanup direct-partial-retry-after-readd "$buyer_id" "$cgid" \
    "[{\"product_id\":$partial,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup retry after re-add HTTP" "HTTP $code" ||
    record FAIL "cart cleanup retry after re-add HTTP" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-partial-retry-after-readd.json")"

  get_cart direct-partial-after-readd-retry "$buyer" >/dev/null
  qty="$(cart_qty direct-partial-after-readd-retry "$partial")"
  [[ "$qty" == "5" ]] && record PASS "cart cleanup does not delete re-added items" "qty=$qty" ||
    record FAIL "cart cleanup does not delete re-added items" "qty=$qty expected=5"

  # Full cleanup
  add_to_cart direct-full-initial "$buyer" "$full" 2
  get_cart direct-full-before "$buyer" >/dev/null
  qty="$(cart_qty direct-full-before "$full")"
  [[ "$qty" == "2" ]] && record PASS "cart setup full quantity" "qty=$qty" ||
    record FAIL "cart setup full quantity" "qty=$qty expected=2"

  cgid="$(new_uuid)"
  code="$(internal_cart_cleanup direct-full "$buyer_id" "$cgid" \
    "[{\"product_id\":$full,\"quantity\":2}]")"
  is_2xx "$code" && record PASS "cart cleanup full direct" "HTTP $code cg=$cgid" ||
    record FAIL "cart cleanup full direct" "HTTP $code body=$(body_flat "$HTTP_DIR/cart-cleanup-direct-full.json")"

  get_cart direct-full-after "$buyer" >/dev/null
  qty="$(cart_qty direct-full-after "$full")"
  [[ "$qty" == "0" ]] && record PASS "cart cleanup full removes item" "qty=$qty" ||
    record FAIL "cart cleanup full removes item" "qty=$qty expected=0"

  add_to_cart direct-full-readd "$buyer" "$full" 1
  get_cart direct-full-readd-after "$buyer" >/dev/null
  qty="$(cart_qty direct-full-readd-after "$full")"
  [[ "$qty" == "1" ]] && record PASS "cart hard-delete allows re-add" "qty=$qty" ||
    record FAIL "cart hard-delete allows re-add" "qty=$qty expected=1"
}

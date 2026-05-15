#!/usr/bin/env bash
# cases/34_checkout_idempotency_scoped_by_buyer.sh — Same Idempotency-Key, different buyers
# Depends on: 01_auth_catalog_setup (seller_checkout, seller_a, buyer_checkout, buyer_foreign)
# Purpose: two different buyers using the same Idempotency-Key must NOT share
# checkout_group_id or the purchase. The idempotency scope is buyer_id + key.

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

case_34_checkout_idempotency_scoped_by_buyer() {
  blue "--- 34_checkout_idempotency_scoped_by_buyer ---"

  local buyer_a buyer_b seller_a seller_b
  local product_a product_b
  local idem code cgid_a cgid_b

  buyer_a="$(state_get buyer_checkout_token)"
  buyer_b="$(state_get buyer_foreign_token)"
  seller_a="$(state_get seller_checkout_token)"
  seller_b="$(state_get seller_a_token)"

  if [[ -z "$buyer_a" || -z "$buyer_b" ]]; then
    record SKIP "checkout idempotency scoped" "registering fresh buyers"
    register_user buyer_scope_a
    register_user buyer_scope_b
    buyer_a="$(state_get buyer_scope_a_token)"
    buyer_b="$(state_get buyer_scope_b_token)"
  fi

  if [[ -z "$seller_a" || -z "$seller_b" ]]; then
    register_user seller_scope_a "seller"
    register_user seller_scope_b "seller"
    seller_a="$(state_get seller_scope_a_token)"
    seller_b="$(state_get seller_scope_b_token)"
  fi

  if [[ -z "$buyer_a" || -z "$buyer_b" || -z "$seller_a" || -z "$seller_b" ]]; then
    record SKIP "checkout idempotency scoped" "missing actors after registration"
    return 0
  fi

  # Create two products from two different sellers
  product_name_a="E2E_SCOPE_A_${RUN_ID}"
  product_name_b="E2E_SCOPE_B_${RUN_ID}"
  create_product "$product_name_a" "$seller_a" 120 10
  create_product "$product_name_b" "$seller_b" 99 10

  list_my_products seller_scope_a_list "$seller_a"
  list_my_products seller_scope_b_list "$seller_b"

  product_a="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_scope_a_list.json" "$product_name_a")"
  product_b="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_scope_b_list.json" "$product_name_b")"

  if [[ -z "$product_a" || -z "$product_b" ]]; then
    record FAIL "checkout idempotency scoped products" "missing product_a=$product_a product_b=$product_b"
    return 0
  fi

  record PASS "checkout idempotency scoped products created" "a=$product_a b=$product_b"

  # Buyer A adds product A to cart, Buyer B adds product B to cart
  add_to_cart scope-cart-a "$buyer_a" "$product_a" 1
  add_to_cart scope-cart-b "$buyer_b" "$product_b" 1

  # Both use the SAME Idempotency-Key
  idem="shared-scope-key-${RUN_ID}"

  code="$(checkout scope-a "$buyer_a" "$idem")"
  if is_2xx "$code"; then
    cgid_a="$(json_get "$HTTP_DIR/checkout-scope-a.json" ".checkout_group_id")"
    record PASS "checkout scoped buyer a" "HTTP $code cgid=$cgid_a"
  else
    record FAIL "checkout scoped buyer a" \
      "HTTP $code expected 2xx body=$(body_flat "$HTTP_DIR/checkout-scope-a.json")"
    return 0
  fi

  code="$(checkout scope-b "$buyer_b" "$idem")"
  if is_2xx "$code"; then
    cgid_b="$(json_get "$HTTP_DIR/checkout-scope-b.json" ".checkout_group_id")"
    record PASS "checkout scoped buyer b" "HTTP $code cgid=$cgid_b"
  else
    record FAIL "checkout scoped buyer b" \
      "HTTP $code expected 2xx body=$(body_flat "$HTTP_DIR/checkout-scope-b.json")"
    return 0
  fi

  # Assert checkout_group_ids are DISTINCT
  if [[ -n "$cgid_a" && -n "$cgid_b" && "$cgid_a" != "$cgid_b" ]]; then
    record PASS "checkout idempotency scoped different cgid" \
      "cgid_a=$cgid_a cgid_b=$cgid_b"
  else
    record FAIL "checkout idempotency scoped different cgid" \
      "cgid_a=$cgid_a cgid_b=$cgid_b — same key produced same checkout group across buyers"
  fi

  # Verify buyer A cannot access buyer B's checkout group
  code="$(checkout_group_get scope-a-to-b "$buyer_a" "$cgid_b")"
  assert_forbidden_or_hidden "$code" "checkout scope buyer A blocked from B's cg"

  # Verify buyer B cannot access buyer A's checkout group
  code="$(checkout_group_get scope-b-to-a "$buyer_b" "$cgid_a")"
  assert_forbidden_or_hidden "$code" "checkout scope buyer B blocked from A's cg"

  # Verify buyer A's attempt returns only their own checkout group
  code="$(checkout_attempt_get scope-a-attempt "$buyer_a" "$idem")"
  if is_2xx "$code"; then
    local attempt_cgid
    # The attempt endpoint returns the checkout group itself — `.id` IS the checkout_group_id
    attempt_cgid="$(json_get "$HTTP_DIR/checkout-attempt-scope-a-attempt.json" ".id")"
    [[ -z "$attempt_cgid" ]] && attempt_cgid="$(json_get "$HTTP_DIR/checkout-attempt-scope-a-attempt.json" ".checkout_group_id")"
    if [[ "$attempt_cgid" == "$cgid_a" ]]; then
      record PASS "checkout scope buyer A attempt returns own cgid" "cgid=$attempt_cgid"
    else
      record FAIL "checkout scope buyer A attempt returns own cgid" \
        "expected=$cgid_a got=$attempt_cgid"
    fi
  else
    record SKIP "checkout scope buyer A attempt verification" \
      "HTTP $code — cannot verify attempt isolation"
  fi
}

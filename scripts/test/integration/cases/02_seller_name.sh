#!/usr/bin/env bash
# cases/02_seller_name.sh — Public + seller-owned seller_name coverage
# Depends on: 01_auth_catalog_setup (all actors and products created)
#
# Coverage:
#  1) Public list   GET /catalog/products        — seller_name present, two sellers differ
#  2) Public detail GET /catalog/products/:id    — seller_name matches seller username
#  3) Public home   GET /catalog/home            — seller_name present on run's products
#  4) Edge: two-products-from-different-sellers  — verified via test 1 above
#  5) Edge: seller-owned GET /catalog/me/products — seller_name present for own products

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"

case_02_seller_name() {
  blue "--- 02_seller_name ---"

  # ── Read state from auth/catalog setup ──────────────────────────────────
  local seller_direct_username seller_checkout_username
  local seller_a_username seller_b_username
  local prod_direct_partial prod_direct_full prod_checkout
  local prod_seller_a prod_seller_b
  local seller_direct_token seller_checkout_token

  seller_direct_username="$(state_get seller_direct_username)"
  seller_checkout_username="$(state_get seller_checkout_username)"
  seller_a_username="$(state_get seller_a_username)"
  seller_b_username="$(state_get seller_b_username)"

  prod_direct_partial="$(state_get SDD7_DIRECT_PARTIAL_ID)"
  prod_direct_full="$(state_get SDD7_DIRECT_FULL_ID)"
  prod_checkout="$(state_get SDD7_CHECKOUT_ID)"
  prod_seller_a="$(state_get SDD9_SELLER_A_PRODUCT_ID)"
  prod_seller_b="$(state_get SDD9_SELLER_B_PRODUCT_ID)"

  seller_direct_token="$(state_get seller_direct_token)"
  seller_checkout_token="$(state_get seller_checkout_token)"

  if [[ -z "$seller_direct_username" || -z "$seller_a_username" || -z "$prod_direct_partial" || -z "$prod_seller_a" ]]; then
    record SKIP "seller_name suite" "missing actors or products from setup"
    return 0
  fi

  local code sn

  # ── 1) Public list: GET /catalog/products includes seller_name ──────────
  blue "  > public list seller_name"

  code="$(req "seller-name-public-list" GET "$API_BASE/catalog/products?page=1&page_size=100")"
  assert_http_2xx "$code" "seller-name public list HTTP"

  # Verify seller_name is present on at least one product
  local list_has_sn
  list_has_sn="$(json_field_exists "$HTTP_DIR/seller-name-public-list.json" "seller_name")"
  if [[ "$list_has_sn" == "true" ]]; then
    record PASS "seller-name public list has field" "seller_name present"
  else
    record FAIL "seller-name public list has field" "seller_name missing"
  fi

  # Edge: two products from different sellers carry different seller_name values
  sn="$(json_find_seller_name_by_product_id "$HTTP_DIR/seller-name-public-list.json" "$prod_seller_a")"
  if [[ "$sn" == "$seller_a_username" ]]; then
    record PASS "seller-name public list seller A" "sn=$sn"
  else
    record FAIL "seller-name public list seller A" "expected=$seller_a_username got=$sn"
  fi

  sn="$(json_find_seller_name_by_product_id "$HTTP_DIR/seller-name-public-list.json" "$prod_seller_b")"
  if [[ "$sn" == "$seller_b_username" ]]; then
    record PASS "seller-name public list seller B" "sn=$sn"
  else
    record FAIL "seller-name public list seller B" "expected=$seller_b_username got=$sn"
  fi

  # ── 2) Public detail: GET /catalog/products/:id includes seller_name ────
  blue "  > public detail seller_name"

  code="$(req "seller-name-public-detail" GET "$API_BASE/catalog/products/$prod_direct_partial")"
  assert_http_2xx "$code" "seller-name public detail HTTP"

  sn="$(json_get "$HTTP_DIR/seller-name-public-detail.json" ".seller_name")"
  if [[ "$sn" == "$seller_direct_username" ]]; then
    record PASS "seller-name public detail matches username" "sn=$sn"
  else
    record FAIL "seller-name public detail matches username" "expected=$seller_direct_username got=$sn"
  fi

  # ── 3) Public home: GET /catalog/home includes seller_name ──────────────
  blue "  > public home seller_name"

  code="$(req "seller-name-home" GET "$API_BASE/catalog/home")"
  assert_http_2xx "$code" "seller-name home HTTP"

  # Home may not include every created product — assert presence on any
  # products from this run that do appear in the home response
  local home_has_sn found_one
  home_has_sn="$(json_field_exists "$HTTP_DIR/seller-name-home.json" "seller_name")"
  if [[ "$home_has_sn" == "true" ]]; then
    record PASS "seller-name home has field" "seller_name present"
  else
    record FAIL "seller-name home has field" "seller_name missing"
  fi

  # Check each created product: if it appears in home, seller_name must match
  for pid in "$prod_direct_partial" "$prod_direct_full" "$prod_checkout" "$prod_seller_a" "$prod_seller_b"; do
    [[ -z "$pid" ]] && continue
    sn="$(json_find_seller_name_by_product_id "$HTTP_DIR/seller-name-home.json" "$pid")"
    if [[ -z "$sn" ]]; then
      continue  # product not in home — skip
    fi
    found_one=1

    # Determine expected username
    local expected=""
    case "$pid" in
      "$prod_direct_partial"|"$prod_direct_full") expected="$seller_direct_username" ;;
      "$prod_checkout") expected="$seller_checkout_username" ;;
      "$prod_seller_a") expected="$seller_a_username" ;;
      "$prod_seller_b") expected="$seller_b_username" ;;
    esac

    if [[ "$sn" == "$expected" ]]; then
      record PASS "seller-name home pid=$pid" "sn=$sn"
    else
      record FAIL "seller-name home pid=$pid" "expected=$expected got=$sn"
    fi
  done

  if [[ -z "${found_one:-}" ]]; then
    # No created product appeared in home — not a failure but worth noting
    record PASS "seller-name home (none found)" "no products from this run in home response"
  fi

  # ── 4) Already covered by test 1: two sellers → different seller_name ───

  # ── 5) Seller-owned listing: GET /catalog/me/products includes seller_name
  blue "  > seller-owned listing seller_name"

  # Make fresh calls per seller to keep the test self-contained
  code="$(req "seller-name-me-seller_direct" GET "$API_BASE/catalog/me/products?page=1&page_size=100" "" "$(auth_h "$seller_direct_token")")"
  assert_http_2xx "$code" "seller-name me seller_direct HTTP"

  sn="$(json_find_seller_name_by_product_id "$HTTP_DIR/seller-name-me-seller_direct.json" "$prod_direct_partial")"
  if [[ "$sn" == "$seller_direct_username" ]]; then
    record PASS "seller-name me seller_direct pid matches" "sn=$sn"
  else
    record FAIL "seller-name me seller_direct pid matches" "expected=$seller_direct_username got=$sn"
  fi

  code="$(req "seller-name-me-seller_checkout" GET "$API_BASE/catalog/me/products?page=1&page_size=100" "" "$(auth_h "$seller_checkout_token")")"
  assert_http_2xx "$code" "seller-name me seller_checkout HTTP"

  sn="$(json_find_seller_name_by_product_id "$HTTP_DIR/seller-name-me-seller_checkout.json" "$prod_checkout")"
  if [[ "$sn" == "$seller_checkout_username" ]]; then
    record PASS "seller-name me seller_checkout pid matches" "sn=$sn"
  else
    record FAIL "seller-name me seller_checkout pid matches" "expected=$seller_checkout_username got=$sn"
  fi
}

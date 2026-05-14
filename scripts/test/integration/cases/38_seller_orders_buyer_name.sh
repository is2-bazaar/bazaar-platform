#!/usr/bin/env bash
# cases/38_seller_orders_buyer_name.sh — Validate buyer_name in seller orders via API Gateway
# Depends on: 00_readiness (services up). Registers fresh actors internally.
#
# Coverage:
#  1) Register seller, buyer, intruder seller
#  2) Seller creates product → buyer checks out
#  3) GET /seller/orders          → buyer_name present in list
#  4) GET /seller/orders/{id}     → buyer_name present in detail
#  5) Intruder seller cannot see order nor buyer_name
#  6) buyer_name validation: gateway forwards X-User-Name (username) and
#     X-User-Email (email). Order-service prefers X-User-Name, falling back
#     to X-User-Email only when username is missing. Primary expectation is
#     buyer_username match; buyer_email match is accepted as compatibility
#     (legacy fallback when username was not forwarded).

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

case_38_seller_orders_buyer_name() {
  blue "--- 38_seller_orders_buyer_name ---"

  # ── 1) Register fresh actors ───────────────────────────────────────────
  blue "  > register fresh actors"

  register_user seller_bn "seller"
  register_user buyer_bn "buyer"
  register_user intruder_bn "seller"

  local seller_token buyer_token intruder_token
  local buyer_email buyer_username order_id
  local code cgid product_id

  seller_token="$(state_get seller_bn_token)"
  buyer_token="$(state_get buyer_bn_token)"
  buyer_email="$(state_get buyer_bn_email)"
  buyer_username="$(state_get buyer_bn_username)"
  intruder_token="$(state_get intruder_bn_token)"

  if [[ -z "$seller_token" || -z "$buyer_token" || -z "$intruder_token" ]]; then
    record SKIP "38_seller_orders_buyer_name" "registration failed"
    return 0
  fi

  # ── 2) Seller creates product ──────────────────────────────────────────
  blue "  > seller creates product"

  create_product "BN_PRODUCT_${RUN_ID}" "$seller_token" 99 10
  list_my_products seller_bn_list "$seller_token"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_bn_list.json" "BN_PRODUCT_${RUN_ID}")"

  if [[ -z "$product_id" ]]; then
    record SKIP "38_seller_orders_buyer_name" "product creation failed"
    return 0
  fi
  record PASS "38 product created" "pid=$product_id"

  # ── 3) Buyer checkout ──────────────────────────────────────────────────
  blue "  > buyer checkout"

  add_to_cart bn-add "$buyer_token" "$product_id" 1

  local idem
  idem="bn-buyername-${RUN_ID}"
  code="$(checkout bn-checkout "$buyer_token" "$idem")"
  cgid="$(json_get "$HTTP_DIR/checkout-bn-checkout.json" ".checkout_group_id")"
  order_id="$(json_get "$HTTP_DIR/checkout-bn-checkout.json" ".orders[0].order_id")"
  [[ -z "$order_id" ]] && order_id="$(json_get "$HTTP_DIR/checkout-bn-checkout.json" ".order_id")"

  if ! is_2xx "$code" || [[ -z "$order_id" ]]; then
    record SKIP "38 buyer_name dependent assertions" "checkout failed HTTP=$code order_id=${order_id:-missing}"
    return 0
  fi
  record PASS "38 checkout" "HTTP=$code order_id=$order_id cg=$cgid"

  # ── 4) Seller list: GET /seller/orders  ────────────────────────────────
  blue "  > seller list buyer_name"

  code="$(seller_get_orders bn-list "$seller_token")"
  assert_http_2xx "$code" "38 seller list HTTP"

  local list_has_bn
  list_has_bn="$(json_field_exists "$HTTP_DIR/seller-orders-bn-list.json" "buyer_name")"

  if [[ "$list_has_bn" == "true" ]]; then
    local list_bn_value
    list_bn_value="$(json_find_buyer_name_by_order_id "$HTTP_DIR/seller-orders-bn-list.json" "$order_id")"

    # Primary: gateway forwards X-User-Name (username).
    # Order-service prefers X-User-Name, falling back to X-User-Email only
    # when username is missing.
    if [[ -n "$buyer_username" && "$list_bn_value" == "$buyer_username" ]]; then
      record PASS "38 seller list buyer_name matches username" "buyer_name=$list_bn_value"
    elif [[ "$list_bn_value" == "$buyer_email" ]]; then
      # Compatibility: email used when username was not forwarded.
      record PASS "38 seller list buyer_name matches email (compatibility)" \
        "buyer_name=$list_bn_value (username absent, email fallback)"
    else
      record FAIL "38 seller list buyer_name" \
        "expected username=$buyer_username or email=$buyer_email got=$list_bn_value"
    fi
  else
    # Check alternative field name
    local list_has_bu
    list_has_bu="$(json_field_exists "$HTTP_DIR/seller-orders-bn-list.json" "buyer_username")"
    if [[ "$list_has_bu" == "true" ]]; then
      local list_bu_value
      list_bu_value="$(json_find_buyer_name_by_order_id "$HTTP_DIR/seller-orders-bn-list.json" "$order_id")"
      if [[ "$list_bu_value" == "$buyer_username" ]]; then
        record PASS "38 seller list buyer_username matches" "buyer_username=$list_bu_value"
      else
        record FAIL "38 seller list buyer_username" \
          "expected=$buyer_username got=$list_bu_value"
      fi
    else
      record FAIL "38 seller list buyer_name" \
        "field 'buyer_name' (or 'buyer_username') not present in GET /seller/orders response"
    fi
  fi

  # ── 5) Seller detail: GET /seller/orders/{id} ──────────────────────────
  blue "  > seller detail buyer_name"

  code="$(seller_get_order bn-detail "$seller_token" "$order_id")"
  assert_http_2xx "$code" "38 seller detail HTTP"

  local detail_has_bn
  detail_has_bn="$(json_field_exists "$HTTP_DIR/seller-order-bn-detail.json" "buyer_name")"

  if [[ "$detail_has_bn" == "true" ]]; then
    local detail_bn_value
    detail_bn_value="$(json_get "$HTTP_DIR/seller-order-bn-detail.json" ".buyer_name")"

    # Primary: gateway forwards X-User-Name (username).
    # Order-service prefers X-User-Name, falling back to X-User-Email only
    # when username is missing.
    if [[ -n "$buyer_username" && "$detail_bn_value" == "$buyer_username" ]]; then
      record PASS "38 seller detail buyer_name matches username" "buyer_name=$detail_bn_value"
    elif [[ "$detail_bn_value" == "$buyer_email" ]]; then
      # Compatibility: email used when username was not forwarded.
      record PASS "38 seller detail buyer_name matches email (compatibility)" \
        "buyer_name=$detail_bn_value (username absent, email fallback)"
    else
      record FAIL "38 seller detail buyer_name" \
        "expected username=$buyer_username or email=$buyer_email got=$detail_bn_value"
    fi
  else
    local detail_has_bu
    detail_has_bu="$(json_field_exists "$HTTP_DIR/seller-order-bn-detail.json" "buyer_username")"
    if [[ "$detail_has_bu" == "true" ]]; then
      local detail_bu_value
      detail_bu_value="$(json_get "$HTTP_DIR/seller-order-bn-detail.json" ".buyer_username")"
      if [[ "$detail_bu_value" == "$buyer_username" ]]; then
        record PASS "38 seller detail buyer_username matches" "buyer_username=$detail_bu_value"
      else
        record FAIL "38 seller detail buyer_username" \
          "expected=$buyer_username got=$detail_bu_value"
      fi
    else
      record FAIL "38 seller detail buyer_name" \
        "field 'buyer_name' (or 'buyer_username') not present in GET /seller/orders/{id} response"
    fi
  fi

  # ── 6) Intruder cannot see the order ───────────────────────────────────
  blue "  > intruder isolation"

  code="$(seller_get_order bn-intruder-detail "$intruder_token" "$order_id")"
  assert_forbidden_or_hidden "$code" "38 intruder cannot get seller order detail"

  # Intruder list should be empty or forbidden
  code="$(seller_get_orders bn-intruder-list "$intruder_token")"
  if is_2xx "$code"; then
    local intruder_has_oid
    intruder_has_oid="$(json_find_order_by_id "$HTTP_DIR/seller-orders-bn-intruder-list.json" "$order_id")"
    if [[ "$intruder_has_oid" == "false" ]]; then
      record PASS "38 intruder seller list isolation" "HTTP $code (order not visible)"
    else
      record FAIL "38 intruder seller list isolation" "intruder should not see order_id=$order_id"
    fi
  else
    # Non-2xx is acceptable if backend enforces role isolation at list level
    record PASS "38 intruder seller list blocked" "HTTP $code"
  fi
}

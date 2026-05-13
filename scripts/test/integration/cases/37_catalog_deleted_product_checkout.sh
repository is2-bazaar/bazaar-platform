#!/usr/bin/env bash
# cases/37_catalog_deleted_product_checkout.sh — Product deleted after being in cart cannot be purchased
# Depends on: 01_auth_catalog_setup (seller_checkout, buyer_checkout) or fresh actors
# Purpose: if a seller deletes a product that a buyer has in their cart,
# the checkout must reject it. No confirmed order for a deleted product.

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

case_37_catalog_deleted_product_checkout() {
  blue "--- 37_catalog_deleted_product_checkout ---"

  local seller buyer
  local product_name product_id
  local code idem cgid

  seller="$(state_get seller_checkout_token)"
  buyer="$(state_get buyer_checkout_token)"

  if [[ -z "$seller" || -z "$buyer" ]]; then
    register_user seller_deleted "seller"
    register_user buyer_deleted
    seller="$(state_get seller_deleted_token)"
    buyer="$(state_get buyer_deleted_token)"
    if [[ -z "$seller" || -z "$buyer" ]]; then
      record SKIP "deleted product checkout" "could not register fresh actors"
      return 0
    fi
  fi

  # Create product with stock=5
  product_name="E2E_DEL_CHECKOUT_${RUN_ID}"
  create_product "$product_name" "$seller" 250 5

  list_my_products seller_deleted_list "$seller"
  product_id="$(json_find_product_id_by_name "$HTTP_DIR/catalog-list-mine-seller_deleted_list.json" "$product_name")"

  if [[ -z "$product_id" ]]; then
    record FAIL "deleted product checkout product id" "could not find '$product_name'"
    return 0
  fi

  record PASS "deleted product checkout product created" "id=$product_id"

  # Buyer adds to cart
  add_to_cart del-checkout-cart "$buyer" "$product_id" 1

  # Seller deletes the product
  code="$(req catalog-delete-product DELETE "$API_BASE/catalog/me/products/$product_id" "" "$(auth_h "$seller")")"

  local delete_ok=false
  if is_2xx "$code"; then
    record PASS "deleted product checkout deleted" "HTTP $code — product removed from catalog"
    delete_ok=true
  elif [[ "$code" == "404" || "$code" == "405" ]]; then
    record SKIP "deleted product checkout deleted" \
      "HTTP $code — DELETE endpoint not available or product not found; cannot test this flow"
    delete_ok=false
  elif is_4xx "$code"; then
    record SKIP "deleted product checkout deleted" \
      "HTTP $code — DELETE returned unexpected 4xx; contract unclear"
    delete_ok=false
  else
    record FAIL "deleted product checkout deleted" \
      "HTTP $code body=$(body_flat "$HTTP_DIR/catalog-delete-product.json")"
    return 1
  fi

  if [[ "$delete_ok" != "true" ]]; then
    return 0
  fi

  # Verify public catalog no longer returns the product
  code="$(req del-checkout-verify GET "$API_BASE/catalog/products/$product_id")"
  if [[ "$code" == "404" || "$code" == "410" ]]; then
    record PASS "deleted product checkout public 404" "HTTP $code — product gone from public catalog"
  elif is_4xx "$code"; then
    record PASS "deleted product checkout public hidden" "HTTP $code — product not visible"
  elif is_2xx "$code"; then
    record SKIP "deleted product checkout public hidden" \
      "HTTP $code — product still visible (may be soft-delete)"
  elif [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
    record FAIL "deleted product checkout public hidden" \
      "HTTP $code — server error when checking deleted product"
  else
    record SKIP "deleted product checkout public hidden" "HTTP $code — unexpected"
  fi

  # Buyer attempts checkout with the now-deleted product
  idem="deleted-product-checkout-$RUN_ID"
  code="$(checkout del-product-checkout "$buyer" "$idem")"

  if is_2xx "$code"; then
    cgid="$(json_get "$HTTP_DIR/checkout-del-product-checkout.json" ".checkout_group_id")"
    if [[ -z "$cgid" ]]; then
      record PASS "deleted product checkout rejected" \
        "HTTP $code but no cgid — system returned 2xx without creating checkout group"
    else
      record FAIL "deleted product checkout rejected" \
        "HTTP $code cgid=$cgid — deleted product was purchased! Consistency violation."
    fi
  elif is_4xx "$code"; then
    record PASS "deleted product checkout rejected" "HTTP $code"
  else
    record FAIL "deleted product checkout rejected" \
      "HTTP $code expected 4xx body=$(body_flat "$HTTP_DIR/checkout-del-product-checkout.json")"
  fi

  # Verify no cgid in response
  cgid="$(json_get "$HTTP_DIR/checkout-del-product-checkout.json" ".checkout_group_id")"
  if [[ -z "$cgid" ]]; then
    record PASS "deleted product checkout no cgid" "cgid absent"
  else
    record FAIL "deleted product checkout no cgid" "cgid=$cgid"
  fi

  # Verify no order confirmed
  code="$(buyer_get_orders del-checkout-buyer-orders "$buyer")"
  if is_2xx "$code"; then
    local has_order
    has_order="$(json_field_exists "$HTTP_DIR/buyer-orders-del-checkout-buyer-orders.json" "order_id")"
    if [[ "$has_order" != "true" ]]; then
      record PASS "deleted product checkout no orders" "no order_id found"
    else
      record FAIL "deleted product checkout no orders" "buyer has orders despite failed checkout"
    fi
  else
    record SKIP "deleted product checkout no orders" "HTTP $code — cannot verify orders"
  fi
}

#!/usr/bin/env bash
# cases/37_catalog_deleted_product_checkout.sh — Product deleted after being in cart cannot be purchased
# Always uses fresh isolated actors to avoid cart contamination with shared actors.
# Purpose: if a seller deletes a product that a buyer has in their cart,
# the checkout must reject it with HTTP 409 and structured insufficient_stock_items.
# No confirmed order, no payment, no cart cleanup, and the cart preserves the item.

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

  # Always use fresh isolated actors to avoid contaminating shared state (seller_checkout, buyer_checkout).
  # Shared actors are used by tests 20-36 and 40-47; a deleted product left in their cart
  # causes cascading failures.
  register_user seller_deleted "seller"
  register_user buyer_deleted
  seller="$(state_get seller_deleted_token)"
  buyer="$(state_get buyer_deleted_token)"

  if [[ -z "$seller" || -z "$buyer" ]]; then
    record FAIL "deleted product checkout actors" "could not register fresh actors"
    return 0
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

  # ── Buyer attempts checkout with the now-deleted product ──
  idem="deleted-product-checkout-$RUN_ID"
  code="$(checkout del-product-checkout "$buyer" "$idem")"

  # Require exactly HTTP 409 — NOT any 4xx, NOT 2xx, NOT 500.
  if [[ "$code" != "409" ]]; then
    record FAIL "deleted product checkout returns 409" \
      "HTTP $code expected=409 body=$(body_flat "$HTTP_DIR/checkout-del-product-checkout.json")"
    return 0
  fi
  record PASS "deleted product checkout returns 409" "HTTP 409 Conflict"

  # ── Validate structured 409 body ──
  local response_file="$HTTP_DIR/checkout-del-product-checkout.json"

  local issi_product_id
  issi_product_id="$(json_get "$response_file" ".insufficient_stock_items[0].product_id")"
  if [[ "$issi_product_id" == "$product_id" ]]; then
    record PASS "deleted product checkout body product_id" "product_id=$issi_product_id"
  else
    record FAIL "deleted product checkout body product_id" \
      "expected=$product_id got=$issi_product_id"
  fi

  local issi_reason
  issi_reason="$(json_get "$response_file" ".insufficient_stock_items[0].reason")"
  if [[ "$issi_reason" == "product_not_found" ]]; then
    record PASS "deleted product checkout body reason" "reason=$issi_reason"
  else
    record FAIL "deleted product checkout body reason" \
      "expected=product_not_found got=$issi_reason"
  fi

  local issi_available
  issi_available="$(json_get "$response_file" ".insufficient_stock_items[0].available")"
  if [[ "$issi_available" == "0" ]]; then
    record PASS "deleted product checkout body available" "available=0"
  else
    record FAIL "deleted product checkout body available" \
      "expected=0 got=$issi_available"
  fi

  local issi_requested
  issi_requested="$(json_get "$response_file" ".insufficient_stock_items[0].requested")"
  if [[ "$issi_requested" == "1" ]]; then
    record PASS "deleted product checkout body requested" "requested=1"
  elif [[ -z "$issi_requested" ]]; then
    record SKIP "deleted product checkout body requested" "requested field not present in response"
  else
    record FAIL "deleted product checkout body requested" \
      "expected=1 got=$issi_requested"
  fi

  # ── Verify no checkout_group_id in response ──
  cgid="$(json_get "$response_file" ".checkout_group_id")"
  if [[ -z "$cgid" ]]; then
    record PASS "deleted product checkout no cgid" "cgid absent from error response"
  else
    record FAIL "deleted product checkout no cgid" "cgid=$cgid should not be present in 409 response"
  fi

  # ── Verify no orders created ──
  code="$(buyer_get_orders del-checkout-buyer-orders "$buyer")"
  if is_2xx "$code"; then
    local orders_file="$HTTP_DIR/buyer-orders-del-checkout-buyer-orders.json"
    local total_orders
    total_orders="$(json_get "$orders_file" ".total_count")"

    if [[ -n "$total_orders" ]]; then
      # total_count present → authoritative
      if [[ "$total_orders" == "0" ]]; then
        record PASS "deleted product checkout no orders" "total_count=0"
      else
        record FAIL "deleted product checkout no orders" "total_count=$total_orders — buyer has orders despite failed checkout"
      fi
    else
      # total_count absent → fallback to orders array length
      local orders_len
      orders_len="$(json_array_length "$orders_file" "orders")"
      if [[ -n "$orders_len" ]]; then
        if [[ "$orders_len" == "0" ]]; then
          record PASS "deleted product checkout no orders" "orders_len=0 (total_count absent)"
        else
          record FAIL "deleted product checkout no orders" "orders_len=$orders_len — buyer has orders despite failed checkout"
        fi
      else
        record FAIL "deleted product checkout no orders" "could not determine orders count — neither total_count nor orders array found"
      fi
    fi
  else
    record SKIP "deleted product checkout no orders" "HTTP $code — cannot verify orders"
  fi

  # ── Verify cart is preserved (not cleaned up) ──
  get_cart del-checkout-cart-after "$buyer"
  local cart_qty
  cart_qty="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-del-checkout-cart-after.json" "$product_id")"
  if [[ "$cart_qty" == "1" ]]; then
    record PASS "deleted product checkout cart preserved" "qty=$cart_qty — cart still has the deleted product"
  else
    record FAIL "deleted product checkout cart preserved" \
      "expected qty=1 got=${cart_qty:-missing} — cart was wrongly cleaned or product lost"
  fi
}

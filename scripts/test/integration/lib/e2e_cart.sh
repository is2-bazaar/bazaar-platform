#!/usr/bin/env bash
# e2e_cart.sh — Cart helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_CART_SOURCED:-}" ]] && return 0
_E2E_CART_SOURCED=1

# ---------------------------------------------------------------------------
# add_to_cart — add item to buyer's cart
# ---------------------------------------------------------------------------
add_to_cart() {
  local label="$1"
  local token="$2"
  local product_id="$3"
  local qty="$4"

  local payload="{\"product_id\":$product_id,\"quantity\":$qty}"
  local code
  code="$(req "cart-add-$label" POST "$API_BASE/cart/items" "$payload" "$(auth_h "$token")")"

  if is_2xx "$code"; then
    record PASS "cart add $label" "product=$product_id qty=$qty"
    return 0
  fi

  record FAIL "cart add $label" "HTTP $code product=$product_id qty=$qty body=$(body_flat "$HTTP_DIR/cart-add-$label.json")"
  return 1
}

# ---------------------------------------------------------------------------
# get_cart — fetch buyer's cart
# ---------------------------------------------------------------------------
get_cart() {
  local label="$1"
  local token="$2"
  req "cart-get-$label" GET "$API_BASE/cart/" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# cart_qty — get quantity of a product in the cart (uses json helper)
# ---------------------------------------------------------------------------
cart_qty() {
  local label="$1"
  local product_id="$2"
  json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-$label.json" "$product_id"
}

# ---------------------------------------------------------------------------
# internal_cart_cleanup — call cart-service internal checkout cleanup
# ---------------------------------------------------------------------------
internal_cart_cleanup() {
  local label="$1"
  local buyer_id="$2"
  local checkout_group_id="$3"
  local items_json="$4"

  local payload
  payload="$(
    cat <<JSON
{
  "buyer_id": $buyer_id,
  "checkout_group_id": "$checkout_group_id",
  "items": $items_json
}
JSON
  )"

  req "cart-cleanup-$label" POST "$CART_BASE/internal/checkout-cleanup" "$payload" "$(cart_internal_h)"
}

#!/usr/bin/env bash
# e2e_orders.sh — Order helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_ORDERS_SOURCED:-}" ]] && return 0
_E2E_ORDERS_SOURCED=1

# ---------------------------------------------------------------------------
# Seller endpoints
# ---------------------------------------------------------------------------
seller_get_orders() {
  local label="$1"
  local token="$2"
  req "seller-orders-$label" GET "$API_BASE/seller/orders?page=1&page_size=20" "" "$(auth_h "$token")"
}

seller_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "seller-order-$label" GET "$API_BASE/seller/orders/$order_id" "" "$(auth_h "$token")"
}

seller_update_order_status() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  local status="$4"
  local tracking_code="${5:-}"

  local payload
  if [[ -n "$tracking_code" ]]; then
    payload="{\"status\":\"$status\",\"tracking_code\":\"$tracking_code\"}"
  else
    payload="{\"status\":\"$status\"}"
  fi

  req "seller-update-status-$label" POST "$API_BASE/seller/orders/$order_id/status" "$payload" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Seller cancel — POST /seller/orders/:id/cancel
# ---------------------------------------------------------------------------
seller_cancel_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "seller-cancel-$label" POST "$API_BASE/seller/orders/$order_id/cancel" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Buyer endpoints
# ---------------------------------------------------------------------------
buyer_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "buyer-order-$label" GET "$API_BASE/orders/$order_id" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Buyer list orders — GET /orders/
# ---------------------------------------------------------------------------
buyer_get_orders() {
  local label="$1"
  local token="$2"
  req "buyer-orders-$label" GET "$API_BASE/orders/" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Buyer list orders filtered — GET /orders?status=X
# ---------------------------------------------------------------------------
buyer_get_orders_filtered() {
  local label="$1"
  local token="$2"
  local status="$3"
  req "buyer-orders-$label" GET "$API_BASE/orders?status=$status" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Buyer cancel — POST /orders/:id/cancel
# ---------------------------------------------------------------------------
buyer_cancel_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "buyer-cancel-$label" POST "$API_BASE/orders/$order_id/cancel" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# Buyer confirm delivery — POST /orders/:id/confirm-delivery
# ---------------------------------------------------------------------------
buyer_confirm_delivery() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "buyer-confirm-delivery-$label" POST "$API_BASE/orders/$order_id/confirm-delivery" "" "$(auth_h "$token")"
}

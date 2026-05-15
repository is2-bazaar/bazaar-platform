#!/usr/bin/env bash
# e2e_admin.sh — Admin helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_ADMIN_SOURCED:-}" ]] && return 0
_E2E_ADMIN_SOURCED=1

# ---------------------------------------------------------------------------
# admin_get_orders — GET /admin/orders/
# ---------------------------------------------------------------------------
admin_get_orders() {
  local label="$1"
  local token="$2"
  req "admin-orders-list-$label" GET "$API_BASE/admin/orders/" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# admin_get_order — GET /admin/orders/:order_id
# ---------------------------------------------------------------------------
admin_get_order() {
  local label="$1"
  local token="$2"
  local order_id="$3"
  req "admin-order-detail-$label" GET "$API_BASE/admin/orders/$order_id" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# admin_get_users — GET /admin/users/
# ---------------------------------------------------------------------------
admin_get_users() {
  local label="$1"
  local token="$2"
  req "admin-users-list-$label" GET "$API_BASE/admin/users/" "" "$(auth_h "$token")"
}

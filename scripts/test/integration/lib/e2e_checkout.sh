#!/usr/bin/env bash
# e2e_checkout.sh — Checkout helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_CHECKOUT_SOURCED:-}" ]] && return 0
_E2E_CHECKOUT_SOURCED=1

# ---------------------------------------------------------------------------
# checkout — POST /checkout with delivery address and idempotency key
# ---------------------------------------------------------------------------
checkout() {
  local label="$1"
  local token="$2"
  local idem="$3"
  local payload='{"delivery_address":"Av E2E 123","delivery_city":"CABA","delivery_province":"Buenos Aires"}'
  req "checkout-$label" POST "$API_BASE/checkout" "$payload" "$(auth_h "$token")" "Idempotency-Key: $idem"
}

# ---------------------------------------------------------------------------
# order_id_first — extract the first order_id from a checkout response
# ---------------------------------------------------------------------------
order_id_first() {
  local label="$1"
  local file="$HTTP_DIR/checkout-$label.json"
  local oid
  oid="$(json_get "$file" ".orders[0].order_id")"
  [[ -z "$oid" ]] && oid="$(json_get "$file" ".order_id")"
  printf '%s' "$oid"
}

# ---------------------------------------------------------------------------
# checkout_order_id_for_seller — find order_id by seller_id in checkout response
# ---------------------------------------------------------------------------
checkout_order_id_for_seller() {
  local label="$1"
  local seller_id="$2"
  json_find_order_id_by_seller_id "$HTTP_DIR/checkout-$label.json" "$seller_id"
}

# ---------------------------------------------------------------------------
# checkout_attempt_get — GET /checkout/attempts/:idempotencyKey
# ---------------------------------------------------------------------------
checkout_attempt_get() {
  local label="$1"
  local token="$2"
  local idem="$3"
  req "checkout-attempt-$label" GET "$API_BASE/checkout/attempts/$idem" "" "$(auth_h "$token")"
}

# ---------------------------------------------------------------------------
# checkout_group_get — GET /checkout-groups/:checkoutGroupId
# ---------------------------------------------------------------------------
checkout_group_get() {
  local label="$1"
  local token="$2"
  local cgid="$3"
  req "checkout-group-$label" GET "$API_BASE/checkout-groups/$cgid" "" "$(auth_h "$token")"
}

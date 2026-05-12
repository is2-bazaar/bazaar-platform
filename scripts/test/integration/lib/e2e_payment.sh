#!/usr/bin/env bash
# e2e_payment.sh — Payment callback helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh
#
# Internal callback endpoints (order-service):
#   POST /internal/checkout-groups/{checkoutGroupId}/mark-payment-approved
#   POST /internal/checkout-groups/{checkoutGroupId}/mark-payment-rejected
#   POST /internal/checkout-groups/{checkoutGroupId}/mark-payment-refunded

[[ -n "${_E2E_PAYMENT_SOURCED:-}" ]] && return 0
_E2E_PAYMENT_SOURCED=1

# ---------------------------------------------------------------------------
# internal_callback_approved — call order-service mark-payment-approved
# ---------------------------------------------------------------------------
internal_callback_approved() {
  local label="$1"
  local checkout_group_id="$2"
  local payment_id="${3:-}"
  local provider_payment_id="${4:-mp-cb-${RANDOM}}"

  local pid
  if [[ -z "$payment_id" || "$payment_id" == "null" ]]; then
    pid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  else
    pid="$payment_id"
  fi

  local payload
  payload="{\"payment_id\":\"$pid\",\"provider\":\"mock\",\"provider_payment_id\":\"$provider_payment_id\",\"provider_status\":\"approved\"}"

  req "payment-cb-approved-$label" POST "$ORDER_BASE/internal/checkout-groups/$checkout_group_id/mark-payment-approved" "$payload" "$(internal_h)"
}

# ---------------------------------------------------------------------------
# internal_callback_rejected — call order-service mark-payment-rejected
# ---------------------------------------------------------------------------
internal_callback_rejected() {
  local label="$1"
  local checkout_group_id="$2"
  local payment_id="${3:-}"
  local provider_payment_id="${4:-mp-cb-${RANDOM}}"

  local pid
  if [[ -z "$payment_id" || "$payment_id" == "null" ]]; then
    pid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  else
    pid="$payment_id"
  fi

  local payload
  payload="{\"payment_id\":\"$pid\",\"provider\":\"mock\",\"provider_payment_id\":\"$provider_payment_id\",\"provider_status\":\"rejected\"}"

  req "payment-cb-rejected-$label" POST "$ORDER_BASE/internal/checkout-groups/$checkout_group_id/mark-payment-rejected" "$payload" "$(internal_h)"
}

# ---------------------------------------------------------------------------
# internal_callback_refunded — call order-service mark-payment-refunded
# ---------------------------------------------------------------------------
internal_callback_refunded() {
  local label="$1"
  local checkout_group_id="$2"
  local payment_id="${3:-}"
  local provider_payment_id="${4:-mp-cb-${RANDOM}}"

  local pid
  if [[ -z "$payment_id" || "$payment_id" == "null" ]]; then
    pid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  else
    pid="$payment_id"
  fi

  local payload
  payload="{\"payment_id\":\"$pid\",\"provider\":\"mock\",\"provider_payment_id\":\"$provider_payment_id\",\"provider_status\":\"refunded\"}"

  req "payment-cb-refunded-$label" POST "$ORDER_BASE/internal/checkout-groups/$checkout_group_id/mark-payment-refunded" "$payload" "$(internal_h)"
}

# ---------------------------------------------------------------------------
# payment_checkout — POST /internal/payments (payment-service)
# Used for testing payment-service directly in mock mode.
# ---------------------------------------------------------------------------
payment_create() {
  local label="$1"
  local checkout_group_id="$2"
  local buyer_id="${3:-0}"
  local amount_cents="${4:-10000}"
  local idempotency_key="${5:-}"
  local items_json="${6:-[{\"title\":\"E2E Item\",\"quantity\":1,\"unit_price_cents\":10000}]}"

  local ik
  if [[ -z "$idempotency_key" ]]; then
    ik="payment-e2e-${checkout_group_id}"
  else
    ik="$idempotency_key"
  fi

  local payload
  payload="{\"checkout_group_id\":\"$checkout_group_id\",\"buyer_id\":$buyer_id,\"amount_cents\":$amount_cents,\"currency\":\"ARS\",\"items\":$items_json,\"success_url\":\"http://localhost/success\",\"failure_url\":\"http://localhost/failure\",\"pending_url\":\"http://localhost/pending\",\"idempotency_key\":\"$ik\"}"

  req "payment-create-$label" POST "$PAYMENT_BASE/internal/payments" "$payload" "$(internal_h)" "Idempotency-Key: $ik"
}

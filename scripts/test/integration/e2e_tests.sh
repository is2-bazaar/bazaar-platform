#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E — Modular Test Suite Orchestrator
#
# Runs discrete test cases from cases/ using shared lib/ functions.
# Filter with E2E_CASES env var (comma-separated prefixes).
#
# Usage:
#   E2E_TARGET_ENV=local ./e2e_tests.sh
#   E2E_TARGET_ENV=render E2E_CASES="20,30" ./e2e_tests.sh
###############################################################################

# Require E2E_TARGET_ENV
if [[ -z "${E2E_TARGET_ENV:-}" ]]; then
  echo "ERROR: E2E_TARGET_ENV must be set (local or render)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
CASES_DIR="$SCRIPT_DIR/cases"

# Source all libs in dependency order
source "$LIB_DIR/e2e_common.sh"
e2e_common_init
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_catalog.sh"
source "$LIB_DIR/e2e_cart.sh"
source "$LIB_DIR/e2e_checkout.sh"
source "$LIB_DIR/e2e_orders.sh"
source "$LIB_DIR/e2e_admin.sh"

# Render safety warning
if [[ "$E2E_TARGET_ENV" == "render" ]]; then
  echo "⚠️  WARNING: Running against Render. This creates real data."
fi

# Define case order and their function names (parallel indexed arrays)
CASE_NAMES=(
  "00_readiness"
  "01_auth_catalog_setup"
  "02_seller_name"
  "10_cart_cleanup"
  "20_checkout_approved"
  "21_checkout_insufficient_stock"
  "22_checkout_idempotency"
  "23_checkout_reconciliation_privacy"
  "24_mock_payment_checkout"
  "25_mock_callback_approved"
  "26_mock_callback_rejected"
  "27_mock_callback_idempotency"
  "28_mock_callback_state_transitions"
  "29_checkout_empty_cart"
  "30_seller_orders"
  "31_seller_order_status"
  "32_buyer_orders_history"
  "33_checkout_missing_idempotency_key"
  "34_checkout_idempotency_scoped_by_buyer"
  "36_multiseller_checkout_atomic_stock_failure"
  "37_catalog_deleted_product_checkout"
  "40_cancel_order_buyer"
  "41_cancel_order_seller"
  "42_cancel_order_privacy"
  "43_cancel_order_idempotency"
  "44_cancel_triggers_refund"
  "45_cancel_sent_order_blocked"
  "47_confirm_delivery_privacy"
  "50_admin_readonly"
)

CASE_FUNCS=(
  "case_00_readiness"
  "case_01_auth_catalog_setup"
  "case_02_seller_name"
  "case_10_cart_cleanup"
  "case_20_checkout_approved"
  "case_21_checkout_insufficient_stock"
  "case_22_checkout_idempotency"
  "case_23_checkout_reconciliation_privacy"
  "case_24_mock_payment_checkout"
  "case_25_mock_callback_approved"
  "case_26_mock_callback_rejected"
  "case_27_mock_callback_idempotency"
  "case_28_mock_callback_state_transitions"
  "case_29_checkout_empty_cart"
  "case_30_seller_orders"
  "case_31_seller_order_status"
  "case_32_buyer_orders_history"
  "case_33_checkout_missing_idempotency_key"
  "case_34_checkout_idempotency_scoped_by_buyer"
  "case_36_multiseller_checkout_atomic_stock_failure"
  "case_37_catalog_deleted_product_checkout"
  "case_40_cancel_order_buyer"
  "case_41_cancel_order_seller"
  "case_42_cancel_order_privacy"
  "case_43_cancel_order_idempotency"
  "case_44_cancel_triggers_refund"
  "case_45_cancel_sent_order_blocked"
  "case_47_confirm_delivery_privacy"
  "case_50_admin_readonly"
)

# Parse E2E_CASES filter
RUN_INDICES=()
if [[ -n "${E2E_CASES:-}" ]]; then
  IFS=',' read -ra FILTER <<<"$E2E_CASES"
  for idx in "${!CASE_NAMES[@]}"; do
    local_name="${CASE_NAMES[$idx]}"
    for prefix in "${FILTER[@]}"; do
      prefix="$(echo "$prefix" | xargs)" # trim
      if [[ "$local_name" == "$prefix"* ]]; then
        RUN_INDICES+=("$idx")
        break
      fi
    done
  done
else
  for idx in "${!CASE_NAMES[@]}"; do
    RUN_INDICES+=("$idx")
  done
fi

if [[ ${#RUN_INDICES[@]} -eq 0 ]]; then
  echo "WARNING: No cases matched E2E_CASES filter. Available:" >&2
  printf '  %s\n' "${CASE_NAMES[@]}" >&2
  exit 0
fi

blue "== Bazaar E2E Suite =="
blue "RUN_ID=$RUN_ID  TARGET=$E2E_TARGET_ENV"

for idx in "${RUN_INDICES[@]}"; do
  case_name="${CASE_NAMES[$idx]}"
  func_name="${CASE_FUNCS[$idx]}"
  case_file="$CASES_DIR/${case_name}.sh"

  if [[ ! -f "$case_file" ]]; then
    record SKIP "$case_name" "case file not found"
    continue
  fi

  blue "--- $case_name ---"
  source "$case_file"

  if declare -f "$func_name" >/dev/null 2>&1; then
    # Run case with errexit suspended so one FAIL does not abort the suite
    set +e
    "$func_name"
    set -e
  else
    record FAIL "$case_name" "function $func_name not defined after sourcing"
  fi
done

write_report

blue "== Summary =="
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "REPORT=$REPORT"
echo "RAW=$HTTP_DIR"

if ((FAIL > 0)); then
  red "E2E suite finished with failures."
  exit 1
fi

green "E2E suite finished without blocking failures."

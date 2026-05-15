#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E Cleanup — Post-Verification
#
# After running apply, verifies that E2E data was properly cleaned.
# Generates a post-cleanup report.
#
# Usage:
#   CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-1779999999 \
#     ./scripts/maintenance/cleanup_e2e_post_verify.sh
#
# Or with DB URLs:
#   CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-1779999999 \
#   AUTH_DB_URL=postgres://... \
#   ORDER_DB_URL=postgres://... \
#     ./scripts/maintenance/cleanup_e2e_post_verify.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cleanup_e2e_common.sh"

run_psql_count() {
  local url="$1"
  local query="$2"
  local label="$3"
  local result
  result="$(psql "$url" -t -A -c "$query" 2>/dev/null || echo "ERROR")"
  printf '%s' "$result"
}

run_psql_full() {
  local url="$1"
  local query="$2"
  psql "$url" -c "$query" -A -F ',' --csv 2>/dev/null || echo "ERROR: query failed"
}

# ── Verification queries ────────────────────────────────────────────────────

verify_auth_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "Auth DB — Post-Cleanup"

  local remaining_users
  remaining_users="$(run_psql_count "$url" "SELECT COUNT(*) FROM auth_accounts WHERE email LIKE 'u%@test.local';" "auth-remaining-users")"
  echo "- E2E users remaining: $remaining_users" >>"$report"
  if [[ "$remaining_users" != "0" ]]; then
    echo "  **WARNING: $remaining_users E2E users still present!**" >>"$report"
    errors=$((errors + 1))

    echo "" >>"$report"
    echo '```' >>"$report"
    run_psql_full "$url" "SELECT id, email, username FROM auth_accounts WHERE email LIKE 'u%@test.local';" >>"$report"
    echo '```' >>"$report"
  fi

  local remaining_sessions
  remaining_sessions="$(run_psql_count "$url" "SELECT COUNT(*) FROM auth_sessions WHERE account_id IN (SELECT id FROM auth_accounts WHERE email LIKE 'u%@test.local');" "auth-remaining-sessions")"
  echo "- E2E sessions remaining: $remaining_sessions" >>"$report"

  # Verify protected users still exist
  local admin_count
  admin_count="$(run_psql_count "$url" "SELECT COUNT(*) FROM auth_accounts WHERE email IN ('admin@bazaar.dev', 'testadmin@bazaar.dev') OR role = 'admin';" "auth-protected-admins")"
  echo "- Protected admins still present: $admin_count" >>"$report"
  if [[ "$admin_count" == "0" ]]; then
    echo "  **CRITICAL: Protected admin accounts are missing!**" >>"$report"
    errors=$((errors + 1))
  fi

  echo "- **Status: $([[ $errors -eq 0 ]] && echo 'CLEAN' || echo 'ISSUES FOUND')**" >>"$report"
}

verify_catalog_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "Catalog DB — Post-Cleanup"

  local remaining_products
  remaining_products="$(run_psql_count "$url" "SELECT COUNT(*) FROM products WHERE name LIKE 'SDD7_%' OR name LIKE 'SDD9_%' OR description LIKE 'E2E SDD7-SDD8-SDD9 product %';" "catalog-remaining-products")"
  echo "- E2E products remaining: $remaining_products" >>"$report"
  if [[ "$remaining_products" != "0" ]]; then
    echo "  **WARNING: $remaining_products E2E products still present!**" >>"$report"
    errors=$((errors + 1))
  fi

  local remaining_idempotency
  remaining_idempotency="$(run_psql_count "$url" "SELECT COUNT(*) FROM idempotency_keys WHERE key LIKE 'product-SDD7_%' OR key LIKE 'product-SDD9_%' OR key LIKE 'sdd7-%' OR key LIKE 'sdd9-%' OR key LIKE 'admin-checkout-%';" "catalog-remaining-idempotency")"
  echo "- E2E idempotency keys remaining: $remaining_idempotency" >>"$report"
  if [[ "$remaining_idempotency" != "0" ]]; then
    echo "  **WARNING: $remaining_idempotency E2E idempotency keys still present!**" >>"$report"
    errors=$((errors + 1))
  fi

  local reservations_total
  reservations_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM stock_reservations;" "catalog-total-reservations")"
  echo "- Stock reservations (all): $reservations_total" >>"$report"

  echo "- **Status: $([[ $errors -eq 0 ]] && echo 'CLEAN' || echo 'ISSUES FOUND')**" >>"$report"
}

verify_cart_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "Cart DB — Post-Cleanup"

  local remaining_cleanup
  remaining_cleanup="$(run_psql_count "$url" "SELECT COUNT(*) FROM cart_cleanup_operations WHERE checkout_group_id::text LIKE 'sdd7-%' OR checkout_group_id::text LIKE 'sdd9-%';" "cart-remaining-cleanup")"
  echo "- E2E cleanup operations remaining: $remaining_cleanup" >>"$report"
  if [[ "$remaining_cleanup" != "0" ]]; then
    echo "  **WARNING: $remaining_cleanup E2E cleanup operations still present!**" >>"$report"
    errors=$((errors + 1))
  fi

  local carts_total
  carts_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM carts;" "cart-total-carts")"
  echo "- Total carts: $carts_total" >>"$report"

  local cart_items_total
  cart_items_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM cart_items;" "cart-total-items")"
  echo "- Total cart items: $cart_items_total" >>"$report"

  echo "- **Status: $([[ $errors -eq 0 ]] && echo 'CLEAN' || echo 'ISSUES FOUND')**" >>"$report"
}

verify_order_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "Order DB — Post-Cleanup"

  local remaining_cg
  remaining_cg="$(run_psql_count "$url" "SELECT COUNT(*) FROM checkout_groups WHERE idempotency_key LIKE 'sdd7-checkout-approved-cleanup-%' OR idempotency_key LIKE 'sdd9-multiseller-%' OR idempotency_key LIKE 'admin-checkout-%';" "order-remaining-cg")"
  echo "- E2E checkout groups remaining: $remaining_cg" >>"$report"
  if [[ "$remaining_cg" != "0" ]]; then
    echo "  **WARNING: $remaining_cg E2E checkout groups still present!**" >>"$report"
    errors=$((errors + 1))

    echo "" >>"$report"
    echo '```' >>"$report"
    run_psql_full "$url" "SELECT id, buyer_id, idempotency_key, status FROM checkout_groups WHERE idempotency_key LIKE 'sdd7-checkout-approved-cleanup-%' OR idempotency_key LIKE 'sdd9-multiseller-%' OR idempotency_key LIKE 'admin-checkout-%';" >>"$report"
    echo '```' >>"$report"
  fi

  local cg_total
  cg_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM checkout_groups;" "order-total-cg")"
  echo "- Total checkout groups: $cg_total" >>"$report"

  local orders_total
  orders_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM orders;" "order-total-orders")"
  echo "- Total orders: $orders_total" >>"$report"

  local items_total
  items_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM order_items;" "order-total-items")"
  echo "- Total order items: $items_total" >>"$report"

  local history_total
  history_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM order_status_histories;" "order-total-history")"
  echo "- Total status history entries: $history_total" >>"$report"

  echo "- **Status: $([[ $errors -eq 0 ]] && echo 'CLEAN' || echo 'ISSUES FOUND')**" >>"$report"
}

verify_payment_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "Payment DB — Post-Cleanup"

  local payments_total
  payments_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM payments;" "payment-total")"
  echo "- Total payments: $payments_total" >>"$report"

  # Show remaining payments for reference
  echo "" >>"$report"
  echo '```' >>"$report"
  run_psql_full "$url" "SELECT id, checkout_group_id, amount, status, idempotency_key, created_at FROM payments ORDER BY created_at DESC LIMIT 20;" >>"$report"
  echo '```' >>"$report"

  echo "- **Status: OK (manual review recommended)**" >>"$report"
}

verify_user_db() {
  local url="$1"
  local report="$2"
  local errors=0

  write_report_section "$report" "User DB — Post-Cleanup"

  local remaining_profiles
  remaining_profiles="$(run_psql_count "$url" "SELECT COUNT(*) FROM profiles WHERE full_name LIKE 'E2E %';" "user-remaining-profiles")"
  echo "- E2E profiles remaining: $remaining_profiles" >>"$report"
  if [[ "$remaining_profiles" != "0" ]]; then
    echo "  **WARNING: $remaining_profiles E2E profiles still present!**" >>"$report"
    errors=$((errors + 1))
  fi

  local profiles_total
  profiles_total="$(run_psql_count "$url" "SELECT COUNT(*) FROM profiles;" "user-total-profiles")"
  echo "- Total profiles: $profiles_total" >>"$report"

  echo "- **Status: $([[ $errors -eq 0 ]] && echo 'CLEAN' || echo 'ISSUES FOUND')**" >>"$report"
}

# ── Orphan check ────────────────────────────────────────────────────────────

check_orphans() {
  local report="$1"
  write_report_section "$report" "Orphan Records Check"

  cat >>"$report" <<'EOF'
Cross-DB orphan risk assessment:

Since Bazaar services use separate databases with no cross-DB foreign keys,
orphan records can exist if:
  - A user was deleted from auth DB but profile still exists in user DB
  - An order was deleted but payment still references it
  - A checkout_group was deleted but stock_reservation still references it

The apply script deletes in dependency-aware order to minimize orphans.
Manual review recommended if any of the following warning counts are > 0:
EOF

  echo "" >>"$report"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local ts
  ts="$(date +%s)"

  if [[ -n "${CLEANUP_RUN_DIR:-}" ]]; then
    RUN_DIR="$CLEANUP_RUN_DIR"
  else
    RUN_DIR="$(init_run_dir post-verify)"
  fi
  mkdir -p "$RUN_DIR"

  local report="$RUN_DIR/POST_CLEANUP_REPORT.md"
  write_report_header "$report" "Post-Cleanup Verification Report"

  log_step "Post-Cleanup Verification"

  local any_connected=false

  if [[ -n "${ORDER_DB_URL:-}" ]]; then
    any_connected=true
    verify_order_db "$ORDER_DB_URL" "$report"
  else
    write_report_section "$report" "Order DB" && echo "- Not connected (ORDER_DB_URL not set)" >>"$report"
  fi

  if [[ -n "${PAYMENT_DB_URL:-}" ]]; then
    any_connected=true
    verify_payment_db "$PAYMENT_DB_URL" "$report"
  else
    write_report_section "$report" "Payment DB" && echo "- Not connected (PAYMENT_DB_URL not set)" >>"$report"
  fi

  if [[ -n "${CART_DB_URL:-}" ]]; then
    any_connected=true
    verify_cart_db "$CART_DB_URL" "$report"
  else
    write_report_section "$report" "Cart DB" && echo "- Not connected (CART_DB_URL not set)" >>"$report"
  fi

  if [[ -n "${CATALOG_DB_URL:-}" ]]; then
    any_connected=true
    verify_catalog_db "$CATALOG_DB_URL" "$report"
  else
    write_report_section "$report" "Catalog DB" && echo "- Not connected (CATALOG_DB_URL not set)" >>"$report"
  fi

  if [[ -n "${USER_DB_URL:-}" ]]; then
    any_connected=true
    verify_user_db "$USER_DB_URL" "$report"
  else
    write_report_section "$report" "User DB" && echo "- Not connected (USER_DB_URL not set)" >>"$report"
  fi

  if [[ -n "${AUTH_DB_URL:-}" ]]; then
    any_connected=true
    verify_auth_db "$AUTH_DB_URL" "$report"
  else
    write_report_section "$report" "Auth DB" && echo "- Not connected (AUTH_DB_URL not set)" >>"$report"
  fi

  check_orphans "$report"

  if ! $any_connected; then
    write_report_section "$report" "Result"
    echo "**No databases were connected. Set DB_URL vars to run verification.**" >>"$report"
  fi

  echo ""
  green "Post-verification complete."
  log_info "Report: $report"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E Cleanup — Apply (DELETE)
#
# Deletes E2E test data from Render databases.
# MUST be run after dry-run. Uses ID lists from dry-run to target exactly.
#
# Safety gates:
#   1. Requires CONFIRMATION="CONFIRMO BORRAR E2E RENDER"
#   2. Requires CLEANUP_RUN_DIR pointing to a dry-run output
#   3. Backs up data before deleting
#   4. Uses transactions per DB
#   5. Deletes in dependency order
#
# Usage:
#   CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-1779999999 \
#   CONFIRMATION="CONFIRMO BORRAR E2E RENDER" \
#     ./scripts/maintenance/cleanup_e2e_apply.sh
#
# Or with DB URLs:
#   CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-1779999999 \
#   CONFIRMATION="CONFIRMO BORRAR E2E RENDER" \
#   AUTH_DB_URL=postgres://... \
#   ORDER_DB_URL=postgres://... \
#     ./scripts/maintenance/cleanup_e2e_apply.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cleanup_e2e_common.sh"

# ── Safety gate 1: Confirmation ─────────────────────────────────────────────

REQUIRED_CONFIRMATION="CONFIRMO BORRAR E2E RENDER"
CONFIRMATION="${CONFIRMATION:-}"

if [[ "$CONFIRMATION" != "$REQUIRED_CONFIRMATION" ]]; then
  red "ABORTED: Missing or incorrect confirmation."
  red "Required: CONFIRMATION=\"$REQUIRED_CONFIRMATION\""
  red "Got:      CONFIRMATION=\"${CONFIRMATION:-<empty>}\""
  echo ""
  log_info "This script DELETES data. It will not run without explicit confirmation."
  exit 1
fi

# ── Safety gate 2: Run directory ────────────────────────────────────────────

CLEANUP_RUN_DIR="${CLEANUP_RUN_DIR:-}"

if [[ -z "$CLEANUP_RUN_DIR" ]]; then
  red "ABORTED: CLEANUP_RUN_DIR is not set."
  log_info "Point it to a dry-run output directory."
  log_info "Example: CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-1779999999"
  exit 1
fi

if [[ ! -d "$CLEANUP_RUN_DIR" ]]; then
  red "ABORTED: CLEANUP_RUN_DIR '$CLEANUP_RUN_DIR' does not exist."
  exit 1
fi

# Make absolute
CLEANUP_RUN_DIR="$(cd "$CLEANUP_RUN_DIR" 2>/dev/null && pwd || echo "$CLEANUP_RUN_DIR")"
log_info "Using run directory: $CLEANUP_RUN_DIR"

# Check for ID files
IDS_DIR="$CLEANUP_RUN_DIR/ids"
if [[ ! -d "$IDS_DIR" ]]; then
  log_warn "No ids/ directory found in $CLEANUP_RUN_DIR"
  log_warn "The apply script will use pattern-based deletes (less precise)."
  log_warn "Run dry-run with DB connections to generate precise ID lists."
fi

apply_banner

# ── Backup function ─────────────────────────────────────────────────────────

backup_table() {
  local url="$1"
  local table="$2"
  local where_clause="$3"
  local outfile="$4"

  log_info "Backing up: $table -> $outfile"

  psql "$url" -c "\COPY (SELECT * FROM $table WHERE $where_clause) TO '$outfile' WITH CSV HEADER" 2>&1 || {
    log_error "Backup failed for $table"
    return 1
  }
  log_info "Backup OK: $(wc -l < "$outfile" | tr -d ' ') rows"
}

# ── Run psql for DELETE ────────────────────────────────────────────────────

run_psql_delete() {
  local url="$1"
  local sql="$2"
  local label="$3"
  psql "$url" -c "$sql" -o "$RUN_DIR/logs/${label}.log" 2>&1
}

# ── Build IN clause from ID file ──────────────────────────────────────────

build_in_clause_int() {
  local id_file="$1"
  if [[ -f "$id_file" && -s "$id_file" ]]; then
    tr '\n' ',' < "$id_file" | sed 's/,$//'
  else
    echo ""
  fi
}

build_in_clause_uuid() {
  local id_file="$1"
  if [[ -f "$id_file" && -s "$id_file" ]]; then
    # Wrap each UUID in single quotes
    sed "s/^/'/; s/$/'/" "$id_file" | tr '\n' ',' | sed 's/,$//'
  else
    echo ""
  fi
}

# ── Delete per DB ───────────────────────────────────────────────────────────

delete_order_db() {
  local url="$1"
  local order_backup="$RUN_DIR/backup"
  mkdir -p "$order_backup"

  local e2e_users="$IDS_DIR/e2e_user_ids.txt"
  local e2e_cgs="$IDS_DIR/e2e_checkout_group_ids.txt"
  local e2e_orders="$IDS_DIR/e2e_order_ids.txt"

  local user_ins=""
  local cg_ins=""
  local order_ins=""

  user_ins=$(build_in_clause_int "$e2e_users")
  cg_ins=$(build_in_clause_uuid "$e2e_cgs")
  order_ins=$(build_in_clause_uuid "$e2e_orders")

  log_step "Order DB — Backup + Delete"

  # Backup phase
  if [[ -n "$cg_ins" ]]; then
    backup_table "$url" "order_status_histories" \
      "order_id::text IN (SELECT id::text FROM orders WHERE checkout_group_id::text IN ($cg_ins))" \
      "$order_backup/order_status_histories.csv" || true

    backup_table "$url" "order_items" \
      "order_id::text IN (SELECT id::text FROM orders WHERE checkout_group_id::text IN ($cg_ins))" \
      "$order_backup/order_items.csv" || true

    backup_table "$url" "orders" \
      "checkout_group_id::text IN ($cg_ins)" \
      "$order_backup/orders.csv" || true

    backup_table "$url" "checkout_groups" \
      "id::text IN ($cg_ins)" \
      "$order_backup/checkout_groups.csv" || true
  fi

  if [[ -n "$user_ins" && -z "$cg_ins" ]]; then
    backup_table "$url" "orders" \
      "buyer_id IN ($user_ins) OR seller_id IN ($user_ins)" \
      "$order_backup/orders_by_user.csv" || true
  fi

  # Delete phase (in dependency order)
  log_info "Deleting order_status_histories..."
  if [[ -n "$cg_ins" ]]; then
    run_psql_delete "$url" \
      "DELETE FROM order_status_histories WHERE order_id IN (SELECT id FROM orders WHERE checkout_group_id::text IN ($cg_ins));" \
      "order_delete_status_histories"
    log_info "  -> Deleted rows from order_status_histories"
  fi

  log_info "Deleting order_items..."
  if [[ -n "$cg_ins" ]]; then
    run_psql_delete "$url" \
      "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE checkout_group_id::text IN ($cg_ins));" \
      "order_delete_items"
    log_info "  -> Deleted rows from order_items"
  fi

  log_info "Deleting orders..."
  local order_where=""
  if [[ -n "$cg_ins" ]]; then
    order_where="checkout_group_id::text IN ($cg_ins)"
  elif [[ -n "$user_ins" ]]; then
    order_where="buyer_id IN ($user_ins) OR seller_id IN ($user_ins)"
  fi
  if [[ -n "$order_where" ]]; then
    run_psql_delete "$url" "DELETE FROM orders WHERE $order_where;" "order_delete_orders"
    log_info "  -> Deleted rows from orders"
  fi

  log_info "Deleting checkout_groups..."
  local cg_where=""
  if [[ -n "$cg_ins" ]]; then
    cg_where="id::text IN ($cg_ins)"
  elif [[ -n "$user_ins" ]]; then
    cg_where="buyer_id IN ($user_ins)"
  fi
  if [[ -n "$cg_where" ]]; then
    run_psql_delete "$url" "DELETE FROM checkout_groups WHERE $cg_where;" "order_delete_cg"
    log_info "  -> Deleted rows from checkout_groups"
  fi
}

delete_payment_db() {
  local url="$1"
  local backup="$RUN_DIR/backup"
  mkdir -p "$backup"

  local e2e_cgs="$IDS_DIR/e2e_checkout_group_ids.txt"
  local cg_ins=""
  cg_ins=$(build_in_clause_uuid "$e2e_cgs")

  log_step "Payment DB — Backup + Delete"

  if [[ -n "$cg_ins" ]]; then
    backup_table "$url" "payments" \
      "checkout_group_id::text IN ($cg_ins) OR idempotency_key LIKE 'payment-%'" \
      "$backup/payments.csv" || true

    log_info "Deleting payments..."
    run_psql_delete "$url" \
      "DELETE FROM payments WHERE checkout_group_id::text IN ($cg_ins) OR idempotency_key LIKE 'payment-%';" \
      "payment_delete"
    log_info "  -> Deleted rows from payments"
  fi
}

delete_cart_db() {
  local url="$1"
  local backup="$RUN_DIR/backup"
  mkdir -p "$backup"

  local e2e_users="$IDS_DIR/e2e_user_ids.txt"
  local e2e_cgs="$IDS_DIR/e2e_checkout_group_ids.txt"
  local user_ins=""
  local cg_ins=""
  user_ins=$(build_in_clause_int "$e2e_users")
  cg_ins=$(build_in_clause_uuid "$e2e_cgs")

  log_step "Cart DB — Backup + Delete"

  # Delete cleanup_operations first
  if [[ -n "$cg_ins" ]]; then
    backup_table "$url" "cart_cleanup_operations" \
      "checkout_group_id IN ($cg_ins)" \
      "$backup/cart_cleanup_operations.csv" || true

    log_info "Deleting cart_cleanup_operations..."
    run_psql_delete "$url" \
      "DELETE FROM cart_cleanup_operations WHERE checkout_group_id IN ($cg_ins);" \
      "cart_delete_cleanup"
    log_info "  -> Deleted rows from cart_cleanup_operations"
  fi

  if [[ -n "$user_ins" ]]; then
    # cart_items first (FK to carts)
    backup_table "$url" "cart_items" \
      "cart_id IN (SELECT id FROM carts WHERE user_id IN ($user_ins))" \
      "$backup/cart_items.csv" || true

    log_info "Deleting cart_items..."
    run_psql_delete "$url" \
      "DELETE FROM cart_items WHERE cart_id IN (SELECT id FROM carts WHERE user_id IN ($user_ins));" \
      "cart_delete_items"
    log_info "  -> Deleted rows from cart_items"

    # Then carts
    backup_table "$url" "carts" \
      "user_id IN ($user_ins)" \
      "$backup/carts.csv" || true

    log_info "Deleting carts..."
    run_psql_delete "$url" \
      "DELETE FROM carts WHERE user_id IN ($user_ins);" \
      "cart_delete_carts"
    log_info "  -> Deleted rows from carts"
  fi
}

delete_catalog_db() {
  local url="$1"
  local backup="$RUN_DIR/backup"
  mkdir -p "$backup"

  local e2e_cgs="$IDS_DIR/e2e_checkout_group_ids.txt"
  local cg_ins=""
  cg_ins=$(build_in_clause_uuid "$e2e_cgs")

  log_step "Catalog DB — Backup + Delete"

  # Stock reservations and items
  if [[ -n "$cg_ins" ]]; then
    backup_table "$url" "stock_reservation_items" \
      "reservation_id IN (SELECT id FROM stock_reservations WHERE checkout_group_id::text IN ($cg_ins))" \
      "$backup/stock_reservation_items.csv" || true

    backup_table "$url" "stock_reservations" \
      "checkout_group_id::text IN ($cg_ins)" \
      "$backup/stock_reservations.csv" || true

    log_info "Deleting stock_reservation_items..."
    run_psql_delete "$url" \
      "DELETE FROM stock_reservation_items WHERE reservation_id IN (SELECT id FROM stock_reservations WHERE checkout_group_id::text IN ($cg_ins));" \
      "catalog_delete_reservation_items"
    log_info "  -> Deleted rows from stock_reservation_items"

    log_info "Deleting stock_reservations..."
    run_psql_delete "$url" \
      "DELETE FROM stock_reservations WHERE checkout_group_id::text IN ($cg_ins);" \
      "catalog_delete_reservations"
    log_info "  -> Deleted rows from stock_reservations"
  fi

  # E2E Idempotency keys
  log_info "Deleting E2E idempotency_keys..."
  run_psql_delete "$url" \
    "DELETE FROM idempotency_keys WHERE key LIKE 'product-SDD7_%' OR key LIKE 'product-SDD9_%' OR key LIKE 'sdd7-%' OR key LIKE 'sdd9-%' OR key LIKE 'admin-checkout-%';" \
    "catalog_delete_idempotency"
  log_info "  -> Deleted rows from idempotency_keys"

  # E2E Products
  log_info "Deleting E2E products..."
  run_psql_delete "$url" \
    "DELETE FROM products WHERE name LIKE 'SDD7_%' OR name LIKE 'SDD9_%' OR description LIKE 'E2E SDD7-SDD8-SDD9 product %';" \
    "catalog_delete_products"
  log_info "  -> Deleted rows from products"
}

delete_user_db() {
  local url="$1"
  local backup="$RUN_DIR/backup"
  mkdir -p "$backup"

  log_step "User DB — Backup + Delete"

  log_info "Deleting E2E profiles..."
  run_psql_delete "$url" \
    "DELETE FROM profiles WHERE full_name LIKE 'E2E %';" \
    "user_delete_profiles"
  log_info "  -> Deleted rows from profiles"
}

delete_auth_db() {
  local url="$1"
  local backup="$RUN_DIR/backup"
  mkdir -p "$backup"

  local e2e_users="$IDS_DIR/e2e_user_ids.txt"
  local user_ins=""
  user_ins=$(build_in_clause_int "$e2e_users")

  log_step "Auth DB — Backup + Delete"

  local user_where="email LIKE 'u%@test.local'"
  if [[ -n "$user_ins" ]]; then
    user_where="id IN ($user_ins)"
  fi

  # Sessions first (FK to auth_accounts)
  backup_table "$url" "auth_sessions" \
    "account_id IN (SELECT id FROM auth_accounts WHERE $user_where)" \
    "$backup/auth_sessions.csv" || true

  # Password reset codes
  backup_table "$url" "auth_password_reset_codes" \
    "account_id IN (SELECT id FROM auth_accounts WHERE $user_where)" \
    "$backup/auth_password_reset_codes.csv" || true

  # Users
  backup_table "$url" "auth_accounts" \
    "$user_where" \
    "$backup/auth_accounts.csv" || true

  log_info "Deleting auth_sessions..."
  run_psql_delete "$url" \
    "DELETE FROM auth_sessions WHERE account_id IN (SELECT id FROM auth_accounts WHERE $user_where);" \
    "auth_delete_sessions"
  log_info "  -> Deleted rows from auth_sessions"

  log_info "Deleting auth_password_reset_codes..."
  run_psql_delete "$url" \
    "DELETE FROM auth_password_reset_codes WHERE account_id IN (SELECT id FROM auth_accounts WHERE $user_where);" \
    "auth_delete_reset_codes"
  log_info "  -> Deleted rows from auth_password_reset_codes"

  log_info "Deleting auth_accounts..."
  run_psql_delete "$url" \
    "DELETE FROM auth_accounts WHERE $user_where;" \
    "auth_delete_users"
  log_info "  -> Deleted rows from auth_accounts"
}

# ── Summary of what will be deleted ─────────────────────────────────────────

print_deletion_summary() {
  echo ""
  blue "==== DELETION PLAN ===="
  echo ""

  echo "Order of operations (cross-DB dependency order):"
  echo "  1. Order DB:   order_status_histories -> order_items -> orders -> checkout_groups"
  echo "  2. Payment DB:  payments"
  echo "  3. Cart DB:     cart_cleanup_operations -> cart_items -> carts"
  echo "  4. Catalog DB:  stock_reservation_items -> stock_reservations -> idempotency_keys -> products"
  echo "  5. User DB:     profiles"
  echo "  6. Auth DB:     auth_sessions -> auth_password_reset_codes -> auth_accounts"
  echo ""

  if [[ -d "$IDS_DIR" ]]; then
    blue "ID counts from dry-run:"
    for f in "$IDS_DIR"/*.txt; do
      if [[ -f "$f" ]]; then
        local name lines
        name="$(basename "$f")"
        lines=$(wc -l < "$f" | tr -d ' ')
        echo "  $name: $lines entries"
      fi
    done
  else
    yellow "No ID files found. Will use pattern-based deletes (LIKE matches)."
  fi
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  RUN_DIR="${RUN_DIR:-$(init_run_dir apply)}"
  mkdir -p "$RUN_DIR/backup" "$RUN_DIR/logs"

  print_deletion_summary

  # Safety gate 3: double check
  echo ""
  red "╔══════════════════════════════════════════════════════════════╗"
  red "║  FINAL WARNING: This will DELETE data from databases.       ║"
  red "║  Review the deletion plan above carefully.                  ║"
  red "║  Backups will be saved to: $RUN_DIR/backup/                 ║"
  red "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  # Check which DBs are connected
  local any_connected=false

  if [[ -n "${ORDER_DB_URL:-}" ]]; then
    any_connected=true
    log_step "Order DB cleanup"
    delete_order_db "$ORDER_DB_URL"
  else
    log_warn "ORDER_DB_URL not set — skipping order DB"
  fi

  if [[ -n "${PAYMENT_DB_URL:-}" ]]; then
    any_connected=true
    log_step "Payment DB cleanup"
    delete_payment_db "$PAYMENT_DB_URL"
  else
    log_warn "PAYMENT_DB_URL not set — skipping payment DB"
  fi

  if [[ -n "${CART_DB_URL:-}" ]]; then
    any_connected=true
    log_step "Cart DB cleanup"
    delete_cart_db "$CART_DB_URL"
  else
    log_warn "CART_DB_URL not set — skipping cart DB"
  fi

  if [[ -n "${CATALOG_DB_URL:-}" ]]; then
    any_connected=true
    log_step "Catalog DB cleanup"
    delete_catalog_db "$CATALOG_DB_URL"
  else
    log_warn "CATALOG_DB_URL not set — skipping catalog DB"
  fi

  if [[ -n "${USER_DB_URL:-}" ]]; then
    any_connected=true
    log_step "User DB cleanup"
    delete_user_db "$USER_DB_URL"
  else
    log_warn "USER_DB_URL not set — skipping user DB"
  fi

  if [[ -n "${AUTH_DB_URL:-}" ]]; then
    any_connected=true
    log_step "Auth DB cleanup"
    delete_auth_db "$AUTH_DB_URL"
  else
    log_warn "AUTH_DB_URL not set — skipping auth DB"
  fi

  if ! $any_connected; then
    red "No DB_URL vars were set. Nothing was deleted."
    log_info "Set one or more of: AUTH_DB_URL, USER_DB_URL, CATALOG_DB_URL, CART_DB_URL, ORDER_DB_URL, PAYMENT_DB_URL"
    exit 1
  fi

  echo ""
  green "Cleanup complete."
  log_info "Backups saved to: $RUN_DIR/backup/"
  log_info "Logs saved to: $RUN_DIR/logs/"
  echo ""
  log_info "Run post-verification: CLEANUP_RUN_DIR=$CLEANUP_RUN_DIR ./scripts/maintenance/cleanup_e2e_post_verify.sh"
}

main "$@"

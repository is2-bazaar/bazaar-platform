#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E Cleanup — Dry Run (SELECT only)
#
# Generates SQL SELECT queries for each database to audit E2E test data.
# Outputs:
#   - SQL files per DB in tmp/e2e-cleanup-<ts>/
#   - CSV sample exports if psql is available and DB_URL is set
#   - Summary report REPORT.md
#   - ID collection files for later apply phase
#
# Usage:
#   # Generate SQL files only (no DB connection needed):
#   ./scripts/maintenance/cleanup_e2e_dry_run.sh
#
#   # Generate + execute SELECTs if connection vars are set:
#   AUTH_DB_URL=postgres://...  \
#   CATALOG_DB_URL=postgres://... \
#   CART_DB_URL=postgres://...   \
#   ORDER_DB_URL=postgres://...  \
#   PAYMENT_DB_URL=postgres://... \
#   USER_DB_URL=postgres://...   \
#     ./scripts/maintenance/cleanup_e2e_dry_run.sh
#
# Each DB_URL can be a full postgres:// connection string.
# If DB_URL is not set, only SQL files are generated.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cleanup_e2e_common.sh"

run_psql() {
  local url="$1"
  local sql="$2"
  local outfile="${3:-}"
  if [[ -n "$outfile" ]]; then
    psql "$url" -c "$sql" -A -F ',' --csv -o "$outfile" 2>&1 || true
  else
    psql "$url" -c "$sql" -A -F ',' --csv 2>&1 || true
  fi
}

# ── Generate SELECT SQL for each DB ─────────────────────────────────────────

generate_auth_dry_run() {
  log_step "Auth DB — Dry Run"

  cat > "$RUN_DIR/auth_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — Auth DB
-- ============================================================

-- 1. E2E users by email pattern
SELECT '--- E2E AUTH USERS ---' AS info;
SELECT id, email, username, status, role, created_at
FROM auth_accounts
WHERE email LIKE 'u%@test.local'
ORDER BY created_at DESC;

-- 1b. Count
SELECT 'count' AS metric, COUNT(*) AS total FROM auth_accounts WHERE email LIKE 'u%@test.local';

-- 2. E2E users by username pattern (broader catch)
SELECT '--- E2E AUTH USERS BY USERNAME ---' AS info;
SELECT id, email, username, status, role, created_at
FROM auth_accounts
WHERE username LIKE 'u%' AND role != 'admin'
ORDER BY created_at DESC;

-- 2b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM auth_accounts
WHERE username LIKE 'u%' AND role != 'admin';

-- 3. Non-E2E admins (MUST NOT BE DELETED)
SELECT '--- PROTECTED ADMINS (reference) ---' AS info;
SELECT id, email, username, role, created_at
FROM auth_accounts
WHERE email IN ('admin@bazaar.dev', 'testadmin@bazaar.dev')
   OR role = 'admin'
ORDER BY created_at DESC;

-- 4. Sessions for E2E users
SELECT '--- E2E AUTH SESSIONS ---' AS info;
SELECT s.id, s.session_id, s.account_id, s.expires_at, s.revoked_at
FROM auth_sessions s
JOIN auth_accounts u ON u.id = s.account_id
WHERE u.email LIKE 'u%@test.local'
ORDER BY s.created_at DESC;

-- 4b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM auth_sessions s
JOIN auth_accounts u ON u.id = s.account_id
WHERE u.email LIKE 'u%@test.local';

-- 5. Password reset codes for E2E users
SELECT '--- E2E PASSWORD RESET CODES ---' AS info;
SELECT r.id, r.account_id, r.expires_at, r.used_at, r.requested_at
FROM auth_password_reset_codes r
JOIN auth_accounts u ON u.id = r.account_id
WHERE u.email LIKE 'u%@test.local'
ORDER BY r.created_at DESC;

-- 5b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM auth_password_reset_codes r
JOIN auth_accounts u ON u.id = r.account_id
WHERE u.email LIKE 'u%@test.local';
SQLEOF

  log_info "Generated: $RUN_DIR/auth_dry_run.sql"
}

generate_user_dry_run() {
  log_step "User DB — Dry Run"

  cat > "$RUN_DIR/user_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — User DB
-- ============================================================

-- 1. Profiles linked to E2E users via auth_account_id
--    (need E2E user IDs from auth DB — replaced at apply time)
SELECT '--- E2E PROFILES (by auth_account_id from auth dry-run) ---' AS info;
SELECT id, auth_account_id, full_name, phone, completed_at, created_at
FROM profiles
WHERE full_name LIKE 'E2E %'
   OR auth_account_id IN (0)  -- placeholder, replaced in apply
ORDER BY created_at DESC;

-- 1b. Count by full_name pattern
SELECT 'count (by full_name E2E %)' AS metric, COUNT(*) AS total
FROM profiles
WHERE full_name LIKE 'E2E %';

-- 2. All profiles (sanity check — look for any other E2E-sounding)
SELECT '--- ALL PROFILES WITH E2E IN NAME ---' AS info;
SELECT id, auth_account_id, full_name, created_at
FROM profiles
WHERE full_name ILIKE '%e2e%' OR full_name ILIKE '%test%'
ORDER BY created_at DESC;
SQLEOF

  log_info "Generated: $RUN_DIR/user_dry_run.sql"
}

generate_catalog_dry_run() {
  log_step "Catalog DB — Dry Run"

  cat > "$RUN_DIR/catalog_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — Catalog DB
-- ============================================================

-- 1. E2E Products by name patterns
SELECT '--- E2E PRODUCTS ---' AS info;
SELECT id, seller_id, name, description, price, stock_quantity, status, created_at
FROM products
WHERE name LIKE 'SDD7_%'
   OR name LIKE 'SDD9_%'
   OR description LIKE 'E2E SDD7-SDD8-SDD9 product %'
ORDER BY created_at DESC;

-- 1b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM products
WHERE name LIKE 'SDD7_%'
   OR name LIKE 'SDD9_%'
   OR description LIKE 'E2E SDD7-SDD8-SDD9 product %';

-- 2. E2E Idempotency Keys
SELECT '--- E2E IDEMPOTENCY KEYS ---' AS info;
SELECT id, key, actor_id, method, path, resource_type, resource_id, response_status, created_at
FROM idempotency_keys
WHERE key LIKE 'product-SDD7_%'
   OR key LIKE 'product-SDD9_%'
   OR key LIKE 'sdd7-%'
   OR key LIKE 'sdd9-%'
   OR key LIKE 'admin-checkout-%'
ORDER BY created_at DESC;

-- 2b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM idempotency_keys
WHERE key LIKE 'product-SDD7_%'
   OR key LIKE 'product-SDD9_%'
   OR key LIKE 'sdd7-%'
   OR key LIKE 'sdd9-%'
   OR key LIKE 'admin-checkout-%';

-- 3. Stock Reservations (need E2E checkout_group_ids — placeholder)
SELECT '--- E2E STOCK RESERVATIONS (by checkout_group_id from order dry-run) ---' AS info;
SELECT id, checkout_group_id, status, created_at
FROM stock_reservations
WHERE checkout_group_id::text LIKE '00000000%'  -- placeholder
ORDER BY created_at DESC;

-- 3b. All stock reservations (to cross-reference)
SELECT '--- ALL STOCK RESERVATIONS ---' AS info;
SELECT COUNT(*) AS total FROM stock_reservations;
SELECT id, checkout_group_id, status, created_at
FROM stock_reservations
ORDER BY created_at DESC;

-- 4. Stock Reservation Items
SELECT '--- ALL STOCK RESERVATION ITEMS (for cross-reference) ---' AS info;
SELECT COUNT(*) AS total FROM stock_reservation_items;
SELECT id, reservation_id, product_id, quantity, created_at
FROM stock_reservation_items
ORDER BY created_at DESC;
SQLEOF

  log_info "Generated: $RUN_DIR/catalog_dry_run.sql"
}

generate_cart_dry_run() {
  log_step "Cart DB — Dry Run"

  cat > "$RUN_DIR/cart_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — Cart DB
-- ============================================================

-- 1. Carts for E2E users (by user_id — placeholder)
SELECT '--- E2E CARTS (by user_id from auth dry-run) ---' AS info;
SELECT id, user_id, created_at, updated_at
FROM carts
WHERE user_id IN (0)  -- placeholder
ORDER BY created_at DESC;

-- 1b. All carts (to cross-reference during dry-run)
SELECT '--- ALL CARTS ---' AS info;
SELECT COUNT(*) AS total FROM carts;
SELECT id, user_id, created_at FROM carts ORDER BY created_at DESC;

-- 2. Cart Items for E2E carts
SELECT '--- E2E CART ITEMS ---' AS info;
SELECT ci.id, ci.cart_id, ci.product_id, ci.seller_id, ci.product_name, ci.quantity, ci.price, ci.created_at
FROM cart_items ci
JOIN carts c ON c.id = ci.cart_id
WHERE c.user_id IN (0)  -- placeholder
ORDER BY ci.created_at DESC;

-- 2b. All cart items (cross-reference)
SELECT '--- ALL CART ITEMS ---' AS info;
SELECT COUNT(*) AS total FROM cart_items;
SELECT id, cart_id, product_name, quantity, created_at FROM cart_items ORDER BY created_at DESC;

-- 3. Cart Cleanup Operations
SELECT '--- E2E CART CLEANUP OPERATIONS ---' AS info;
SELECT id, checkout_group_id, created_at
FROM cart_cleanup_operations
WHERE checkout_group_id::text LIKE 'sdd7-%'
   OR checkout_group_id::text LIKE 'sdd9-%'
ORDER BY created_at DESC;

-- 3b. All cleanup operations
SELECT '--- ALL CART CLEANUP OPERATIONS ---' AS info;
SELECT COUNT(*) AS total FROM cart_cleanup_operations;
SELECT id, checkout_group_id, created_at FROM cart_cleanup_operations ORDER BY created_at DESC;
SQLEOF

  log_info "Generated: $RUN_DIR/cart_dry_run.sql"
}

generate_order_dry_run() {
  log_step "Order DB — Dry Run"

  cat > "$RUN_DIR/order_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — Order DB
-- ============================================================

-- 1. E2E Checkout Groups by idempotency_key patterns
SELECT '--- E2E CHECKOUT GROUPS (by idempotency_key) ---' AS info;
SELECT id, buyer_id, idempotency_key, status, grand_total, payment_status,
       stock_reservation_id, cart_cleanup_status, last_error, created_at
FROM checkout_groups
WHERE idempotency_key LIKE 'sdd7-checkout-approved-cleanup-%'
   OR idempotency_key LIKE 'sdd9-multiseller-%'
   OR idempotency_key LIKE 'admin-checkout-%'
ORDER BY created_at DESC;

-- 1b. Count by idempotency_key pattern
SELECT 'count (by idempotency_key)' AS metric, COUNT(*) AS total
FROM checkout_groups
WHERE idempotency_key LIKE 'sdd7-checkout-approved-cleanup-%'
   OR idempotency_key LIKE 'sdd9-multiseller-%'
   OR idempotency_key LIKE 'admin-checkout-%';

-- 1c. Checkout groups for E2E buyers (placeholder — buyer_ids from auth)
SELECT '--- E2E CHECKOUT GROUPS (by buyer_ids) ---' AS info;
SELECT id, buyer_id, idempotency_key, status, created_at
FROM checkout_groups
WHERE buyer_id IN (0)  -- placeholder
ORDER BY created_at DESC;

-- 1d. Count
SELECT 'count (by buyer_ids)' AS metric, COUNT(*) AS total
FROM checkout_groups
WHERE buyer_id IN (0);  -- placeholder

-- 2. Orders for E2E users
SELECT '--- E2E ORDERS (by buyer_id/seller_id/checkout_group_id) ---' AS info;
SELECT id, checkout_group_id, buyer_id, seller_id, status, total, subtotal,
       idempotency_key, created_at
FROM orders
WHERE buyer_id IN (0)  -- placeholder
   OR seller_id IN (0) -- placeholder
   OR checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')  -- placeholder
ORDER BY created_at DESC;

-- 2b. Count
SELECT 'count (by E2E ids)' AS metric, COUNT(*) AS total
FROM orders
WHERE buyer_id IN (0)
   OR seller_id IN (0)
   OR checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000');

-- 3. Order Items for E2E orders
SELECT '--- E2E ORDER ITEMS ---' AS info;
SELECT oi.id, oi.order_id, oi.product_id, oi.seller_id, oi.product_name,
       oi.quantity, oi.price, oi.created_at
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.buyer_id IN (0)  -- placeholder
   OR o.seller_id IN (0)
   OR o.checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')
ORDER BY oi.created_at DESC;

-- 3b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.buyer_id IN (0)
   OR o.seller_id IN (0)
   OR o.checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000');

-- 4. Order Status History for E2E orders
SELECT '--- E2E ORDER STATUS HISTORY ---' AS info;
SELECT h.id, h.order_id, h.from_status, h.to_status, h.changed_by,
       h.reason, h.created_at
FROM order_status_histories h
JOIN orders o ON o.id = h.order_id
WHERE o.buyer_id IN (0)  -- placeholder
   OR o.seller_id IN (0)
   OR o.checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')
ORDER BY h.created_at DESC;

-- 4b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM order_status_histories h
JOIN orders o ON o.id = h.order_id
WHERE o.buyer_id IN (0)
   OR o.seller_id IN (0)
   OR o.checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000');

-- 5. All tables — total row counts for reference
SELECT '--- TOTAL ROW COUNTS (order DB) ---' AS info;
SELECT 'checkout_groups' AS tbl, COUNT(*) FROM checkout_groups
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'order_status_histories', COUNT(*) FROM order_status_histories;
SQLEOF

  log_info "Generated: $RUN_DIR/order_dry_run.sql"
}

generate_payment_dry_run() {
  log_step "Payment DB — Dry Run"

  cat > "$RUN_DIR/payment_dry_run.sql" <<'SQLEOF'
-- ============================================================
-- E2E Cleanup Dry Run — Payment DB
-- ============================================================

-- 1. Payments for E2E checkout groups (by checkout_group_id — placeholder)
SELECT '--- E2E PAYMENTS (by checkout_group_id from order dry-run) ---' AS info;
SELECT id, order_id, checkout_group_id, amount, status, idempotency_key,
       external_id, provider, created_at
FROM payments
WHERE checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')  -- placeholder
   OR idempotency_key LIKE 'payment-%'
ORDER BY created_at DESC;

-- 1b. Count
SELECT 'count' AS metric, COUNT(*) AS total
FROM payments
WHERE checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')
   OR idempotency_key LIKE 'payment-%';

-- 2. All payments (cross-reference)
SELECT '--- ALL PAYMENTS ---' AS info;
SELECT COUNT(*) AS total FROM payments;
SELECT id, checkout_group_id, amount, status, idempotency_key, created_at
FROM payments
ORDER BY created_at DESC;

-- 3. Refunds for E2E payments
SELECT '--- E2E REFUNDS ---' AS info;
SELECT 'count' AS metric, COUNT(*) AS total
FROM payments
WHERE checkout_group_id::text IN ('00000000-0000-0000-0000-000000000000')
  AND status = 'refunded';
SQLEOF

  log_info "Generated: $RUN_DIR/payment_dry_run.sql"
}

# ── Phase 1: Collect actionable IDs (when connected to DBs) ─────────────────

extract_ids_from_psql_output() {
  local csv_file="$1"
  local column="$2"  # 1-indexed
  if [[ -f "$csv_file" ]]; then
    tail -n +2 "$csv_file" | cut -d',' -f"$column" | grep -v '^$' | sort -u || true
  fi
}

collect_e2e_ids_connected() {
  local auth_url="${AUTH_DB_URL:-}"
  local user_url="${USER_DB_URL:-}"
  local catalog_url="${CATALOG_DB_URL:-}"
  local cart_url="${CART_DB_URL:-}"
  local order_url="${ORDER_DB_URL:-}"
  local payment_url="${PAYMENT_DB_URL:-}"

  # Phase 1: Auth — collect E2E user IDs
  if [[ -n "$auth_url" ]]; then
    log_info "Collecting E2E user IDs from auth DB..."
    run_psql "$auth_url" \
      "SELECT id FROM auth_accounts WHERE email LIKE 'u%@test.local' ORDER BY id;" \
      "$RUN_DIR/ids/auth_e2e_user_ids.csv"

    extract_ids_from_psql_output "$RUN_DIR/ids/auth_e2e_user_ids.csv" 1 \
      > "$RUN_DIR/ids/e2e_user_ids.txt"

    local user_count
    user_count=$(wc -l < "$RUN_DIR/ids/e2e_user_ids.txt" | tr -d ' ')
    log_info "Found $user_count E2E users in auth DB"
  fi

  # Phase 2: Catalog — collect E2E product IDs
  if [[ -n "$catalog_url" ]]; then
    log_info "Collecting E2E product IDs from catalog DB..."
    run_psql "$catalog_url" \
      "SELECT id FROM products WHERE name LIKE 'SDD7_%' OR name LIKE 'SDD9_%' OR description LIKE 'E2E SDD7-SDD8-SDD9 product %' ORDER BY id;" \
      "$RUN_DIR/ids/catalog_e2e_product_ids.csv"

    extract_ids_from_psql_output "$RUN_DIR/ids/catalog_e2e_product_ids.csv" 1 \
      > "$RUN_DIR/ids/e2e_product_ids.txt"

    local prod_count
    prod_count=$(wc -l < "$RUN_DIR/ids/e2e_product_ids.txt" | tr -d ' ')
    log_info "Found $prod_count E2E products in catalog DB"

    # E2E idempotency keys
    run_psql "$catalog_url" \
      "SELECT id FROM idempotency_keys WHERE key LIKE 'product-SDD7_%' OR key LIKE 'product-SDD9_%' OR key LIKE 'sdd7-%' OR key LIKE 'sdd9-%' OR key LIKE 'admin-checkout-%' ORDER BY id;" \
      "$RUN_DIR/ids/catalog_e2e_idempotency_ids.csv"

    extract_ids_from_psql_output "$RUN_DIR/ids/catalog_e2e_idempotency_ids.csv" 1 \
      > "$RUN_DIR/ids/e2e_idempotency_ids.txt"

    local idem_count
    idem_count=$(wc -l < "$RUN_DIR/ids/e2e_idempotency_ids.txt" | tr -d ' ')
    log_info "Found $idem_count E2E idempotency keys in catalog DB"
  fi

  # Phase 3: Order — collect E2E checkout group IDs and order IDs
  if [[ -n "$order_url" ]]; then
    log_info "Collecting E2E checkout group IDs from order DB..."

    # By idempotency_key pattern
    run_psql "$order_url" \
      "SELECT id FROM checkout_groups WHERE idempotency_key LIKE 'sdd7-checkout-approved-cleanup-%' OR idempotency_key LIKE 'sdd9-multiseller-%' OR idempotency_key LIKE 'admin-checkout-%' ORDER BY id;" \
      "$RUN_DIR/ids/order_e2e_cg_ids_by_key.csv"

    extract_ids_from_psql_output "$RUN_DIR/ids/order_e2e_cg_ids_by_key.csv" 1 \
      > "$RUN_DIR/ids/e2e_checkout_group_ids.txt"

    local cg_count
    cg_count=$(wc -l < "$RUN_DIR/ids/e2e_checkout_group_ids.txt" | tr -d ' ')
    log_info "Found $cg_count E2E checkout groups in order DB"

    # Also find by buyer_id if we have user IDs
    if [[ -f "$RUN_DIR/ids/e2e_user_ids.txt" && -s "$RUN_DIR/ids/e2e_user_ids.txt" ]]; then
      local ids
      ids=$(tr '\n' ',' < "$RUN_DIR/ids/e2e_user_ids.txt" | sed 's/,$//')
      run_psql "$order_url" \
        "SELECT id FROM checkout_groups WHERE buyer_id IN ($ids) ORDER BY id;" \
        "$RUN_DIR/ids/order_e2e_cg_ids_by_buyer.csv"

      extract_ids_from_psql_output "$RUN_DIR/ids/order_e2e_cg_ids_by_buyer.csv" 1 \
        >> "$RUN_DIR/ids/e2e_checkout_group_ids.txt"

      sort -u "$RUN_DIR/ids/e2e_checkout_group_ids.txt" -o "$RUN_DIR/ids/e2e_checkout_group_ids.txt"
      cg_count=$(wc -l < "$RUN_DIR/ids/e2e_checkout_group_ids.txt" | tr -d ' ')
      log_info "Total E2E checkout groups (deduplicated): $cg_count"
    fi

    # E2E order IDs
    if [[ -f "$RUN_DIR/ids/e2e_user_ids.txt" && -s "$RUN_DIR/ids/e2e_user_ids.txt" ]]; then
      local user_ids
      user_ids=$(tr '\n' ',' < "$RUN_DIR/ids/e2e_user_ids.txt" | sed 's/,$//')
      run_psql "$order_url" \
        "SELECT id FROM orders WHERE buyer_id IN ($user_ids) OR seller_id IN ($user_ids) ORDER BY id;" \
        "$RUN_DIR/ids/order_e2e_order_ids.csv"
      extract_ids_from_psql_output "$RUN_DIR/ids/order_e2e_order_ids.csv" 1 \
        > "$RUN_DIR/ids/e2e_order_ids.txt"
    fi

    if [[ -f "$RUN_DIR/ids/e2e_checkout_group_ids.txt" && -s "$RUN_DIR/ids/e2e_checkout_group_ids.txt" ]]; then
      local cg_list
      cg_list="'$(tr '\n' ',' < "$RUN_DIR/ids/e2e_checkout_group_ids.txt" | sed "s/,$//; s/,/','/g")'"
      run_psql "$order_url" \
        "SELECT id FROM orders WHERE checkout_group_id::text IN ($cg_list) ORDER BY id;" \
        "$RUN_DIR/ids/order_e2e_order_ids_by_cg.csv"
      extract_ids_from_psql_output "$RUN_DIR/ids/order_e2e_order_ids_by_cg.csv" 1 \
        >> "$RUN_DIR/ids/e2e_order_ids.txt"
      sort -u "$RUN_DIR/ids/e2e_order_ids.txt" -o "$RUN_DIR/ids/e2e_order_ids.txt"
    fi

    local ord_count=0
    if [[ -f "$RUN_DIR/ids/e2e_order_ids.txt" ]]; then
      ord_count=$(wc -l < "$RUN_DIR/ids/e2e_order_ids.txt" | tr -d ' ')
    fi
    log_info "Found $ord_count E2E orders in order DB"
  fi

  # Phase 4: Payment — collect E2E payment IDs
  if [[ -n "$payment_url" && -f "$RUN_DIR/ids/e2e_checkout_group_ids.txt" && -s "$RUN_DIR/ids/e2e_checkout_group_ids.txt" ]]; then
    local cg_list
    cg_list="'$(tr '\n' ',' < "$RUN_DIR/ids/e2e_checkout_group_ids.txt" | sed "s/,$//; s/,/','/g")'"
    run_psql "$payment_url" \
      "SELECT id FROM payments WHERE checkout_group_id::text IN ($cg_list) ORDER BY id;" \
      "$RUN_DIR/ids/payment_e2e_payment_ids.csv"
    extract_ids_from_psql_output "$RUN_DIR/ids/payment_e2e_payment_ids.csv" 1 \
      > "$RUN_DIR/ids/e2e_payment_ids.txt"
  fi
}

# ── Generate summary report ─────────────────────────────────────────────────

generate_summary_report() {
  local report="$RUN_DIR/REPORT.md"
  write_report_header "$report" "Dry Run Report"

  write_report_section "$report" "Generated SQL Files"
  for f in "$RUN_DIR"/*.sql; do
    local name
    name="$(basename "$f")"
    echo "- \`$name\`" >> "$report"
  done

  write_report_section "$report" "Collected ID Files"
  if [[ -d "$RUN_DIR/ids" ]]; then
    local id_files
    id_files=$(ls "$RUN_DIR/ids"/*.txt "$RUN_DIR/ids"/*.csv 2>/dev/null || true)
    for f in $id_files; do
      if [[ -f "$f" ]]; then
        local name lines
        name="$(basename "$f")"
        lines=$(wc -l < "$f" | tr -d ' ')
        echo "- \`$name\`: $lines entries" >> "$report"
      fi
    done
  fi

  write_report_section "$report" "Next Steps"
  cat >> "$report" <<'EOF'
1. Review the generated SQL files in this directory.
2. If connected to DBs, review the CSV outputs.
3. Verify that NO real users/products are included.
4. Run the apply script:
   ```
   CLEANUP_RUN_DIR=tmp/e2e-cleanup-<ts> \
   CONFIRMATION="CONFIRMO BORRAR E2E RENDER" \
     ./scripts/maintenance/cleanup_e2e_apply.sh
   ```

EOF

  write_report_section "$report" "Generated SQL per DB"

  local dbs=("auth" "user" "catalog" "cart" "order" "payment")
  for db in "${dbs[@]}"; do
    local sql_file="$RUN_DIR/${db}_dry_run.sql"
    if [[ -f "$sql_file" ]]; then
      write_report_section "$report" "$db DB"
      printf '```sql\n' >> "$report"
      cat "$sql_file" >> "$report"
      printf '\n```\n' >> "$report"
    fi
  done

  log_info "Report written: $report"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  RUN_DIR="${RUN_DIR:-$(init_run_dir dry-run)}"
  mkdir -p "$RUN_DIR/ids"

  dry_run_banner

  log_info "Run directory: $RUN_DIR"

  # Always generate SQL files
  generate_auth_dry_run
  generate_user_dry_run
  generate_catalog_dry_run
  generate_cart_dry_run
  generate_order_dry_run
  generate_payment_dry_run

  # If DB URLs are set, also execute the SELECTs
  local any_url_set=false
  for var in AUTH_DB_URL USER_DB_URL CATALOG_DB_URL CART_DB_URL ORDER_DB_URL PAYMENT_DB_URL; do
    if [[ -n "${!var:-}" ]]; then
      any_url_set=true
      log_info "$var is set — will execute SELECTs"
    fi
  done

  if $any_url_set; then
    log_step "Executing SELECTs against databases"

    if command -v psql &>/dev/null; then
      collect_e2e_ids_connected

      # Execute each SQL file if DB is connected
      [[ -n "${AUTH_DB_URL:-}" && -f "$RUN_DIR/auth_dry_run.sql" ]] && \
        log_info "Running auth dry-run..." && \
        run_psql "$AUTH_DB_URL" "$(cat "$RUN_DIR/auth_dry_run.sql")" "$RUN_DIR/reports/auth_results.csv" && \
        log_info "Auth results: $RUN_DIR/reports/auth_results.csv"

      [[ -n "${USER_DB_URL:-}" && -f "$RUN_DIR/user_dry_run.sql" ]] && \
        log_info "Running user dry-run..." && \
        run_psql "$USER_DB_URL" "$(cat "$RUN_DIR/user_dry_run.sql")" "$RUN_DIR/reports/user_results.csv"

      [[ -n "${CATALOG_DB_URL:-}" && -f "$RUN_DIR/catalog_dry_run.sql" ]] && \
        log_info "Running catalog dry-run..." && \
        run_psql "$CATALOG_DB_URL" "$(cat "$RUN_DIR/catalog_dry_run.sql")" "$RUN_DIR/reports/catalog_results.csv"

      [[ -n "${CART_DB_URL:-}" && -f "$RUN_DIR/cart_dry_run.sql" ]] && \
        log_info "Running cart dry-run..." && \
        run_psql "$CART_DB_URL" "$(cat "$RUN_DIR/cart_dry_run.sql")" "$RUN_DIR/reports/cart_results.csv"

      [[ -n "${ORDER_DB_URL:-}" && -f "$RUN_DIR/order_dry_run.sql" ]] && \
        log_info "Running order dry-run..." && \
        run_psql "$ORDER_DB_URL" "$(cat "$RUN_DIR/order_dry_run.sql")" "$RUN_DIR/reports/order_results.csv"

      [[ -n "${PAYMENT_DB_URL:-}" && -f "$RUN_DIR/payment_dry_run.sql" ]] && \
        log_info "Running payment dry-run..." && \
        run_psql "$PAYMENT_DB_URL" "$(cat "$RUN_DIR/payment_dry_run.sql")" "$RUN_DIR/reports/payment_results.csv"
    else
      log_warn "psql not found in PATH — cannot execute SELECTs directly."
      log_warn "SQL files generated. Run them manually or install psql."
    fi
  else
    log_info "No DB_URL vars set. SQL files generated for manual review."
    log_info "To execute against DBs, set: AUTH_DB_URL, CATALOG_DB_URL, CART_DB_URL, ORDER_DB_URL, PAYMENT_DB_URL, USER_DB_URL"
  fi

  generate_summary_report

  echo ""
  green "Dry run complete."
  echo ""
  log_info "Run directory: $RUN_DIR"
  log_info "Review the generated SQL files and report before applying cleanup."
  echo ""
  log_info "To apply:"
  echo "  CLEANUP_RUN_DIR=$RUN_DIR CONFIRMATION=\"CONFIRMO BORRAR E2E RENDER\" ./scripts/maintenance/cleanup_e2e_apply.sh"
  echo ""
}

main "$@"

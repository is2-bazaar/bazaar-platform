#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar — Delete Render Seed Products
#
# Deletes demo products previously inserted by seed_render_products.sh.
# Identifies products by name prefix RENDER_SEED_PRODUCT_ and optionally
# by batch ID.
#
# Safety:
#   - Requires CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" (unless DRY_RUN)
#   - Shows count and sample BEFORE deleting
#   - Creates CSV backup in run directory before DELETE
#   - Never deletes non-seed products (SDD7, SDD9, E2E, real products)
#   - Dry-run shows what would be deleted without touching data
#   - Runs DELETE in a transaction
#
# Usage:
#
#   # Delete ALL seed products (all batches):
#   CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" \
#     ./scripts/maintenance/delete_render_seed_products.sh
#
#   # Delete only a specific batch:
#   CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" \
#     RENDER_SEED_BATCH_ID=demo-may-2026 \
#     ./scripts/maintenance/delete_render_seed_products.sh
#
#   # Dry-run (preview only, no deletion):
#   DRY_RUN=true ./scripts/maintenance/delete_render_seed_products.sh
#
# Environment variables:
#   CATALOG_DB_URL         (auto-loaded from .env.cleanup or export)
#   RENDER_SEED_BATCH_ID   Optional: delete only this batch
#   CONFIRMATION           Must be "CONFIRMO BORRAR PRODUCTOS SEED RENDER"
#   DRY_RUN                If "true", show preview only
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/seed_products_common.sh"

main() {
  # ── Confirmation gate ───────────────────────────────────────────────────────

  DRY_RUN="${DRY_RUN:-false}"
  if [[ "$DRY_RUN" != "true" ]]; then
    require_delete_confirmation
  fi

  # ── Validate environment ────────────────────────────────────────────────────

  check_psql
  require_catalog_url

  local batch_id="${RENDER_SEED_BATCH_ID:-}"

  # ── Build WHERE clause and run dir ──────────────────────────────────────────

  local where_clause
  where_clause="$(build_seed_product_where "$batch_id")"

  local run_label
  if [[ -n "$batch_id" ]]; then
    run_label="delete-${batch_id}"
  else
    run_label="delete-all"
  fi

  local run_dir="${RUN_DIR:-$(init_seed_run_dir "$run_label")}"
  mkdir -p "$run_dir"/{logs,backup,reports}

  log_info "Batch filter: ${batch_id:-<ALL batches>}"
  log_info "WHERE:        $where_clause"
  log_info "Run dir:      $run_dir"
  log_info "Dry run:      $DRY_RUN"

  # ── Count matching products ─────────────────────────────────────────────────

  log_step "Counting matching products..."

  local total
  total="$(psql "$CATALOG_DB_URL" -t -A -c \
    "SELECT COUNT(*) FROM products WHERE $where_clause;" \
    2>/dev/null || echo "0")"
  total="${total//[[:space:]]/}"
  total="${total:-0}"

  log_info "Products matching: $total"

  if [[ "$total" -eq 0 ]]; then
    echo ""
    green "No seed products found matching the criteria."
    log_info "Nothing to delete."
    exit 0
  fi

  # ── Show sample ─────────────────────────────────────────────────────────────

  log_step "Sample of products to delete (up to 10):"
  echo ""
  psql "$CATALOG_DB_URL" -c \
    "SELECT id, seller_id, name, price, category, status FROM products WHERE $where_clause ORDER BY name LIMIT 10;" \
    2>&1 || true
  echo ""

  # ── Dry-run exit ────────────────────────────────────────────────────────────

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    blue "==== DRY RUN ===="
    echo ""
    echo "Would delete:  $total products"
    echo "WHERE clause:  $where_clause"
    echo "Run directory: $run_dir"
    echo ""
    blue "No data was deleted (DRY_RUN=true)."
    echo ""
    echo "To actually delete:"
    echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
    if [[ -n "$batch_id" ]]; then
      echo "    RENDER_SEED_BATCH_ID=$batch_id \\"
    fi
    echo "    ./scripts/maintenance/delete_render_seed_products.sh"
    exit 0
  fi

  # ── Backup to CSV ───────────────────────────────────────────────────────────

  local backup_file="$run_dir/backup/render_seed_products.csv"
  log_step "Creating CSV backup: $backup_file"

  if psql "$CATALOG_DB_URL" -c "\COPY (SELECT * FROM products WHERE $where_clause ORDER BY name) TO '$backup_file' WITH CSV HEADER" 2>&1; then
    local backup_rows
    backup_rows="$(wc -l <"$backup_file" | tr -d ' ')"
    log_info "Backup OK: $backup_rows rows (including header)"
  else
    red "[seed][error]  Backup failed. Aborting delete."
    exit 1
  fi

  # ── Final warning ───────────────────────────────────────────────────────────

  delete_seed_banner
  delete_final_warning
  echo ""
  echo "  Products to delete: $total"
  echo "  WHERE clause:       $where_clause"
  echo "  Backup:             $backup_file"
  echo ""

  # ── Delete ──────────────────────────────────────────────────────────────────

  local delete_sql="$run_dir/delete_seed_products.sql"
  local delete_log="$run_dir/logs/delete_psql.log"

  {
    echo "-- Bazaar Delete Render Seed Products"
    echo "-- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "-- Products to delete: $total"
    echo "-- WHERE: $where_clause"
    echo ""
    echo "BEGIN;"
    echo "DELETE FROM products WHERE $where_clause;"
    echo "COMMIT;"
  } >"$delete_sql"

  log_step "Executing DELETE against Render catalog DB..."
  log_info "SQL file: $delete_sql"

  if psql "$CATALOG_DB_URL" -f "$delete_sql" -o "$delete_log" 2>&1; then
    log_info "DELETE executed successfully."
  else
    red "[seed][error]  DELETE execution failed. Check log: $delete_log"
    log_info "The transaction should have been rolled back automatically."
    log_info "Your backup is safe at: $backup_file"
    exit 1
  fi

  # ── Verify ──────────────────────────────────────────────────────────────────

  log_step "Verifying deletion..."

  local remaining
  remaining="$(psql "$CATALOG_DB_URL" -t -A -c \
    "SELECT COUNT(*) FROM products WHERE $where_clause;" \
    2>/dev/null || echo "?")"
  remaining="${remaining//[[:space:]]/}"
  remaining="${remaining:-?}"

  local deleted=$((total - remaining))

  # ── Report ──────────────────────────────────────────────────────────────────

  local report_file="$run_dir/reports/delete_report.md"
  {
    echo "# Render Seed Products — Delete Report"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`${batch_id:-<ALL>}\`"
    echo "- **Run directory**: \`$run_dir\`"
    echo ""
    echo "## Results"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Products before delete | $total |"
    echo "| Products after delete  | $remaining |"
    echo "| Deleted                | $deleted |"
    echo ""
    echo "## Files"
    echo ""
    echo "- Backup: \`$backup_file\`"
    echo "- SQL:    \`$delete_sql\`"
    echo "- Log:    \`$delete_log\`"
  } >"$report_file"

  # ── Summary ─────────────────────────────────────────────────────────────────

  echo ""
  green "==== DELETE COMPLETE ===="
  echo ""
  echo "  Deleted:    $deleted of $total products"
  echo "  Remaining:  $remaining"
  echo "  Backup:     $backup_file"
  echo "  Run dir:    $run_dir"
  echo ""

  if [[ "$remaining" != "0" ]]; then
    yellow "  WARNING: $remaining products still match the criteria."
    log_info "This may indicate partial deletion. Check the log: $delete_log"
  fi

  green "Done."
}

main "$@"

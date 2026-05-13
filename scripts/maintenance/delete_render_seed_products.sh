#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar — Delete Render Seed Products
#
# Deletes demo products previously created by seed_render_products.sh.
# Identifies products by a marker in the description field via the API,
# optionally filtered by batch ID.
#
# Safety:
#   - Requires CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" (unless DRY_RUN)
#   - Lists products via API and shows count + sample BEFORE deleting
#   - Creates JSON backup in run directory before DELETE
#   - Never deletes non-seed products (requires RENDER_SEED batch= marker in description)
#   - Dry-run shows what would be deleted without touching data
#
# Usage:
#
#   # Delete ALL seed products (all batches):
#   CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" \
#     SEED_SELLER_EMAIL="seller@example.com" \
#     SEED_SELLER_PASSWORD="..." \
#     ./scripts/maintenance/delete_render_seed_products.sh
#
#   # Delete only a specific batch:
#   CONFIRMATION="CONFIRMO BORRAR PRODUCTOS SEED RENDER" \
#     SEED_SELLER_EMAIL="seller@example.com" \
#     SEED_SELLER_PASSWORD="..." \
#     RENDER_SEED_BATCH_ID=demo-may-2026 \
#     ./scripts/maintenance/delete_render_seed_products.sh
#
#   # Dry-run (preview only, no deletion):
#   DRY_RUN=true ./scripts/maintenance/delete_render_seed_products.sh
#
# Environment variables:
#   RENDER_API_BASE_URL    Gateway base URL (auto-loaded from .env.cleanup)
#   SEED_SELLER_EMAIL      Seller email for authentication
#   SEED_SELLER_PASSWORD   Seller password
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

  check_curl
  require_api_base_url

  local batch_id="${RENDER_SEED_BATCH_ID:-}"

  # ── Setup run directory (MUST come before any API calls) ────────────────────

  local run_label
  if [[ -n "$batch_id" ]]; then
    run_label="delete-${batch_id}"
  else
    run_label="delete-all"
  fi

  local run_dir="${RUN_DIR:-$(init_seed_run_dir "$run_label")}"
  # If init_seed_run_dir ran in a command substitution (subshell),
  # RUN_DIR and SEED_HTTP_DIR are not visible. Set them explicitly.
  export RUN_DIR="$run_dir"
  export SEED_HTTP_DIR="${SEED_HTTP_DIR:-$run_dir/http}"
  mkdir -p "$run_dir"/{logs,backup,reports} "$SEED_HTTP_DIR"

  # ── Authenticate seller (needed even for dry-run listing) ──────────────────

  # Listing is read-only, so we auth even in dry-run to show real data.
  # If seller credentials are not set, dry-run won't show real products
  # but still works as a preview of the prefix/pattern.
  if [[ -n "${SEED_SELLER_EMAIL:-}" && -n "${SEED_SELLER_PASSWORD:-}" ]]; then
    seed_login
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "SEED_SELLER_EMAIL/SEED_SELLER_PASSWORD not set."
      log_info "Skipping API listing. Set credentials to see real products."
    else
      red "[seed][error]  SEED_SELLER_EMAIL and SEED_SELLER_PASSWORD must be set."
      log_info "Provide them via environment or .env.cleanup"
      exit 1
    fi
  fi

  local marker
  marker="$(seed_product_batch_marker "$batch_id")"

  log_info "Batch filter: ${batch_id:-<ALL batches>}"
  log_info "Desc marker:  $marker"
  log_info "Run dir:      $run_dir"
  log_info "Dry run:      $DRY_RUN"

  # ── List products via API ───────────────────────────────────────────────────

  local ids_file="$run_dir/seed_product_ids.txt"
  local names_file="$run_dir/seed_product_names.txt"
  local total=0

  if [[ -n "${SEED_TOKEN:-}" ]]; then
    log_step "Fetching seller products via API..."

    local list_label="seed-delete-list"
    local code
    code="$(seed_api_req "$list_label" GET "/catalog/me/products?page=1&page_size=100")"

    if ! is_2xx "$code"; then
      red "[seed][error]  Failed to list products. HTTP $code"
      local err_body
      err_body="$(cat "$SEED_HTTP_DIR/${list_label}.json" 2>/dev/null | tr '\n' ' ' | head -c 300)"
      log_info "Response: ${err_body}"
      exit 1
    fi

    local list_file="$SEED_HTTP_DIR/${list_label}.json"

    # Check if there are more pages
    local total_pages
    total_pages="$(seed_json_get "$list_file" "total_pages")"
    total_pages="${total_pages:-1}"

    if [[ "$total_pages" -gt 1 ]]; then
      log_info "Seller has $total_pages pages of products. Fetching all pages..."
      local pages_fetched
      pages_fetched="$(seed_fetch_all_products "seed-delete-list" "$total_pages" 100)"

      if [[ "$pages_fetched" -lt "$total_pages" ]]; then
        yellow "[seed][warn]  Fetched $pages_fetched of $total_pages pages. Some products may be missed."
      fi
    fi

    # ── Identify seed products ──────────────────────────────────────────────────

    log_step "Identifying seed products by description marker..."

    : >"$ids_file"
    : >"$names_file"

    local page=1
    while [[ $page -le "${total_pages:-1}" ]]; do
      local page_file="$SEED_HTTP_DIR/seed-delete-list-p${page}.json"
      if [[ ! -f "$page_file" ]]; then
        page_file="$list_file" # fallback to first page
      fi

      seed_find_product_ids_by_desc_marker "$page_file" "$marker" >>"$ids_file" 2>/dev/null || true
      seed_list_products_with_names_by_desc_marker "$page_file" "$marker" >>"$names_file" 2>/dev/null || true

      if [[ "$page_file" == "$list_file" ]]; then
        break # only one page was fetched
      fi
      page=$((page + 1))
    done

    total="$(wc -l <"$ids_file" | tr -d ' ')"
    total="${total:-0}"

    log_info "Products matching marker: $total"

    if [[ "$total" -eq 0 ]]; then
      echo ""
      green "No seed products found matching the criteria."
      log_info "Nothing to delete."
      exit 0
    fi

    # ── Show sample ─────────────────────────────────────────────────────────────

    log_step "Sample of products to delete (up to 10):"
    echo ""
    head -10 "$names_file" | sed 's/|/  |  /' || true
    echo ""
  else
    log_info "Not authenticated — skipping product listing."
    log_info "Description marker that would be used: $marker"
  fi

  # ── Dry-run exit ────────────────────────────────────────────────────────────

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    blue "==== DRY RUN ===="
    echo ""
    if [[ -n "${SEED_TOKEN:-}" ]]; then
      echo "Would delete:  $total products"
      echo "Full product list: $names_file"
    else
      echo "Would delete products with description marker: $marker"
      echo "Set SEED_SELLER_EMAIL/SEED_SELLER_PASSWORD to list real products."
      log_info "In dry-run without auth, we show the marker pattern only."
    fi
    echo "Desc marker:   $marker"
    echo "Run directory: $run_dir"
    echo ""
    blue "No data was deleted (DRY_RUN=true)."
    echo ""
    echo "To actually delete:"
    echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
    echo "    SEED_SELLER_EMAIL=\"seller@example.com\" \\"
    echo "    SEED_SELLER_PASSWORD=\"...\" \\"
    if [[ -n "$batch_id" ]]; then
      echo "    RENDER_SEED_BATCH_ID=$batch_id \\"
    fi
    echo "    ./scripts/maintenance/delete_render_seed_products.sh"
    exit 0
  fi

  # ── Backup to JSON ──────────────────────────────────────────────────────────

  local backup_file="$run_dir/backup/render_seed_products.json"
  log_step "Creating JSON backup: $backup_file"

  local backup_count
  backup_count="$(seed_backup_filtered_products "$SEED_HTTP_DIR" "$marker" "seed-delete-list" "$backup_file")"

  log_info "Backup saved: $backup_count products written to $backup_file"

  # ── Final warning ───────────────────────────────────────────────────────────

  delete_seed_banner
  delete_final_warning
  echo ""
  echo "  Products to delete: $total"
  echo "  Desc marker:        $marker"
  echo "  Backup:             $backup_file"
  echo ""

  # ── Delete products via API ─────────────────────────────────────────────────

  local delete_log="$run_dir/logs/delete_api.log"
  local deleted=0
  local del_failed=0

  {
    echo "# Bazaar Delete Render Seed Products — API log"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`${batch_id:-<ALL>}\`"
    echo "- **Desc marker**: \`$marker\`"
    echo "- **Seller email**: \`$SEED_SELLER_EMAIL\`"
    echo ""
    echo "## Deletions"
    echo ""
  } >"$delete_log"

  log_step "Deleting $total products via API..."

  local pid pname
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue

    # Find the name for logging
    pname="$(grep "^${pid}|" "$names_file" 2>/dev/null | head -1 | cut -d'|' -f2- || echo "unknown")"

    local del_label="seed-delete-${pid}"
    local del_code
    del_code="$(seed_api_req "$del_label" DELETE "/catalog/me/products/${pid}")"

    if is_2xx "$del_code" || [[ "$del_code" == "404" ]]; then
      # 404 also counts as "deleted" (already gone)
      green "  Deleted: ${pname:0:80}  (HTTP $del_code)"
      {
        echo "- \`$pname\` (id=$pid) → HTTP $del_code ✓"
      } >>"$delete_log"
      deleted=$((deleted + 1))
    else
      red "  FAILED: ${pname:0:80}  (HTTP $del_code)"
      local err_body
      err_body="$(cat "$SEED_HTTP_DIR/${del_label}.json" 2>/dev/null | tr '\n' ' ' | head -c 200)"
      {
        echo "- \`$pname\` (id=$pid) → HTTP $del_code ✗  body: ${err_body}"
      } >>"$delete_log"
      del_failed=$((del_failed + 1))
    fi
  done <"$ids_file"

  # ── Verify via API list ─────────────────────────────────────────────────────

  log_step "Verifying deletion (fetching all pages)..."

  seed_api_req "seed-delete-verify" GET "/catalog/me/products?page=1&page_size=100" >/dev/null

  local verify_total_pages
  verify_total_pages="$(seed_json_get "$SEED_HTTP_DIR/seed-delete-verify.json" "total_pages")"
  verify_total_pages="${verify_total_pages:-1}"

  if [[ "$verify_total_pages" -gt 1 ]]; then
    seed_fetch_all_products "seed-delete-verify" "$verify_total_pages" 100 >/dev/null
  fi

  local remaining
  remaining="$(seed_count_products_across_pages "seed-delete-verify" "$marker" "$verify_total_pages")"
  remaining="${remaining:-0}"

  log_info "Products remaining after deletion: $remaining"

  # ── Report ──────────────────────────────────────────────────────────────────

  local report_file="$run_dir/reports/delete_report.md"
  {
    echo "# Render Seed Products — Delete Report"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`${batch_id:-<ALL>}\`"
    echo "- **Desc marker**: \`$marker\`"
    echo "- **Seller email**: \`$SEED_SELLER_EMAIL\`"
    echo "- **Run directory**: \`$run_dir\`"
    echo ""
    echo "## Results"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Products before delete | $total |"
    echo "| Products after delete  | $remaining |"
    echo "| Deleted (HTTP success) | $deleted |"
    echo "| Failed deletions       | $del_failed |"
    echo ""
    echo "## Files"
    echo ""
    echo "- Backup: \`$backup_file\`"
    echo "- API log: \`$delete_log\`"
    echo "- HTTP traces: \`$SEED_HTTP_DIR\`"
  } >"$report_file"

  # ── Summary ─────────────────────────────────────────────────────────────────

  echo ""
  green "==== DELETE COMPLETE ===="
  echo ""
  echo "  Deleted:    $deleted of $total products"
  if [[ "$del_failed" -gt 0 ]]; then
    red "  Failed:     $del_failed"
  fi
  echo "  Remaining:  $remaining"
  echo "  Backup:     $backup_file"
  echo "  Run dir:    $run_dir"
  echo ""

  local had_error=0

  if [[ "$remaining" -gt 0 ]]; then
    red "  ERROR: $remaining products still match the criteria after deletion."
    log_info "This indicates incomplete deletion. Check the log: $delete_log"
    had_error=1
  fi

  if [[ "$del_failed" -gt 0 ]]; then
    red "  ERROR: $del_failed deletions failed. Check the log and HTTP traces."
    had_error=1
  fi

  if [[ "$had_error" -eq 1 ]]; then
    exit 1
  fi

  green "Done."
}

main "$@"

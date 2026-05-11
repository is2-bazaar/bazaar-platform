#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar Render Seed Products — Common Library
#
# Shared functions for:
#   seed_render_products.sh
#   delete_render_seed_products.sh
#
# Sources cleanup_e2e_common.sh for colors, logging, env loading,
# sql_escape, sql_quote, require_env, and PLATFORM_ROOT detection.
#
# Do NOT source this directly unless you also need E2E cleanup variables.
###############################################################################

SEED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SEED_LIB_DIR/cleanup_e2e_common.sh"

# ── Run directory (seed-specific, overrides cleanup_e2e one) ──────────────────

init_seed_run_dir() {
  local label="${1:-seed}"
  local ts
  ts="$(date +%s)"
  RUN_DIR="$PLATFORM_ROOT/tmp/render-product-${label}-${ts}"
  mkdir -p "$RUN_DIR"/{logs,backup,reports}
  echo "$RUN_DIR"
}

# ── Banners ───────────────────────────────────────────────────────────────────

seed_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║     RENDER SEED — POPULATE DEMO PRODUCTS                    ║
║                                                            ║
║  INSERTS demo products into Render catalog DB.             ║
║  Target:  Render / Neon  (CATALOG_DB_URL)                  ║
║  Batch:   ${RENDER_SEED_BATCH_ID:-<auto>}                         ║
║  Count:   ${SEED_PRODUCTS_COUNT:-50}                               ║
║  Seller:  ${SEED_SELLER_ID:-<auto-detect>}                        ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

delete_seed_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║     RENDER SEED — DELETE DEMO PRODUCTS                      ║
║                                                            ║
║  DELETES seed products from Render catalog DB.             ║
║  Target:  Render / Neon  (CATALOG_DB_URL)                  ║
║  Batch:   ${RENDER_SEED_BATCH_ID:-<ALL batches>}                  ║
║  Pattern: RENDER_SEED_PRODUCT_%                             ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

delete_final_warning() {
  cat <<WARN

╔══════════════════════════════════════════════════════════════╗
║  FINAL WARNING: This will DELETE data from Render.          ║
║  Review the preview above carefully.                        ║
║  A CSV backup will be saved to the run directory.           ║
╚══════════════════════════════════════════════════════════════╝

WARN
}

# ── Validation ───────────────────────────────────────────────────────────────

check_psql() {
  if ! command -v psql &>/dev/null; then
    red "[seed][error]  psql is not installed or not in PATH."
    log_info "Install it: brew install libpq (macOS) or apt install postgresql-client (Linux)"
    exit 1
  fi
}

require_catalog_url() {
  if [[ -z "${CATALOG_DB_URL:-}" ]]; then
    red "[seed][error]  CATALOG_DB_URL is not set."
    log_info "Set it via scripts/maintenance/.env.cleanup or export CATALOG_DB_URL"
    exit 1
  fi
  log_info "CATALOG_DB_URL: [set]"
}

# ── Seller ID resolution ─────────────────────────────────────────────────────

#
# find_existing_seller_id
#
# Queries the catalog DB for an existing seller_id.
# Returns the ID on stdout (just the number), or exits with 1 if none found.
#
find_existing_seller_id() {
  local result
  result="$(psql "$CATALOG_DB_URL" -t -A -c \
    "SELECT seller_id FROM products WHERE status = 'active' ORDER BY seller_id LIMIT 1;" \
    2>/dev/null || echo "")"
  result="${result//[[:space:]]/}"
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result"
}

#
# resolve_seller_id
#
# Priority:
#   1. $SEED_SELLER_ID env var
#   2. Auto-detect from catalog DB
#   3. Abort with clear message
#
# IMPORTANT: all diagnostic output goes to stderr. Only the seller ID
# (or nothing) goes to stdout, because this function is used in $(...).
#
resolve_seller_id() {
  if [[ -n "${SEED_SELLER_ID:-}" ]]; then
    printf "[seed][info]  Using SEED_SELLER_ID from environment: [set]\n" >&2
    echo "$SEED_SELLER_ID"
    return 0
  fi

  printf "[seed][info]  SEED_SELLER_ID not set — auto-detecting from catalog DB...\n" >&2
  local detected
  if detected="$(find_existing_seller_id)"; then
    printf "[seed][info]  Auto-detected seller_id: [found]\n" >&2
    echo "$detected"
    return 0
  fi

  red "[seed][error]  No SEED_SELLER_ID set and no existing seller found in catalog DB." >&2
  printf "[seed][info]  Provide one via: SEED_SELLER_ID=<id> ./scripts/maintenance/seed_render_products.sh\n" >&2
  exit 1
}

# ── SQL escape (aliases to cleanup_e2e_common.sh helpers) ─────────────────────
# sql_escape and sql_quote are already available from cleanup_e2e_common.sh

#
# escape_like <string>
#
# Escapes _ and % for safe use in PostgreSQL LIKE patterns.
#
escape_like() {
  printf '%s' "$1" | sed 's/_/\\_/g; s/%/\\%/g'
}

#
# build_seed_product_where <batch_id>
#
# Builds a SQL WHERE clause targeting seed products.
# If batch_id is empty, returns clause for ALL seed products.
# Otherwise, targets only that specific batch.
#
build_seed_product_where() {
  local batch="$1"
  local prefix
  prefix="$(escape_like "RENDER_SEED_PRODUCT")"
  if [[ -n "$batch" ]]; then
    local escaped_batch
    escaped_batch="$(escape_like "$batch")"
    echo "name LIKE '${prefix}\\_${escaped_batch}\\_%'"
  else
    echo "name LIKE '${prefix}\\_%'"
  fi
}

# ── Confirmation helpers ─────────────────────────────────────────────────────

require_seed_confirmation() {
  local required="CONFIRMO POBLAR PRODUCTOS RENDER"
  local got="${CONFIRMATION:-}"
  if [[ "$got" != "$required" ]]; then
    red "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    red "  ABORTED: Missing or incorrect confirmation."
    red "  Required: CONFIRMATION=\"$required\""
    red "  Got:      CONFIRMATION=\"${got:-<empty>}\""
    red "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "This script WRITES data to Render. It will not run without explicit confirmation."
    log_info ""
    log_info "Usage:"
    log_info "  CONFIRMATION=\"$required\" ./scripts/maintenance/seed_render_products.sh"
    log_info ""
    log_info "Dry-run (no confirmation needed):"
    log_info "  DRY_RUN=true ./scripts/maintenance/seed_render_products.sh"
    exit 1
  fi
}

require_delete_confirmation() {
  local required="CONFIRMO BORRAR PRODUCTOS SEED RENDER"
  local got="${CONFIRMATION:-}"
  if [[ "$got" != "$required" ]]; then
    red "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    red "  ABORTED: Missing or incorrect confirmation."
    red "  Required: CONFIRMATION=\"$required\""
    red "  Got:      CONFIRMATION=\"${got:-<empty>}\""
    red "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "This script DELETES data from Render. It will not run without explicit confirmation."
    log_info ""
    log_info "Usage:"
    log_info "  CONFIRMATION=\"$required\" ./scripts/maintenance/delete_render_seed_products.sh"
    log_info ""
    log_info "Dry-run (no confirmation needed):"
    log_info "  DRY_RUN=true ./scripts/maintenance/delete_render_seed_products.sh"
    exit 1
  fi
}

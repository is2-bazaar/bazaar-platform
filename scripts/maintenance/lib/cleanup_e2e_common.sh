#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar E2E Cleanup — Common Library
#
# Shared functions and constants for:
#   cleanup_e2e_dry_run.sh
#   cleanup_e2e_apply.sh
#   cleanup_e2e_post_verify.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINTENANCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_ROOT="$(cd "$MAINTENANCE_DIR/../.." && pwd)"

# Auto-load .env.cleanup if present (contains DB connection strings)
if [[ -f "$MAINTENANCE_DIR/.env.cleanup" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$MAINTENANCE_DIR/.env.cleanup"
  set +a
fi

# ── Configuration ────────────────────────────────────────────────────────────

E2E_EMAIL_PATTERN="u%@test.local"
E2E_USERNAME_PATTERN="u%"
E2E_FULL_NAME_PATTERN="E2E %"

E2E_PRODUCT_PATTERNS=(
  "SDD7_DIRECT_PARTIAL_%"
  "SDD7_DIRECT_FULL_%"
  "SDD7_CHECKOUT_%"
  "SDD9_SELLER_A_%"
  "SDD9_SELLER_B_%"
)

E2E_PRODUCT_DESC_PATTERN="E2E SDD7-SDD8-SDD9 product %"

E2E_IDEMPOTENCY_PATTERNS=(
  "product-SDD7_DIRECT_PARTIAL_%"
  "product-SDD7_DIRECT_FULL_%"
  "product-SDD7_CHECKOUT_%"
  "product-SDD9_SELLER_A_%"
  "product-SDD9_SELLER_B_%"
  "sdd7-checkout-approved-cleanup-%"
  "sdd9-multiseller-%"
  "admin-checkout-%"
)

# ── Color helpers ────────────────────────────────────────────────────────────

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[34m%s\033[0m\n" "$*"; }

# ── Logging ──────────────────────────────────────────────────────────────────

log_info()  { printf "[cleanup][info] %s\n" "$*"; }
log_warn()  { yellow "[cleanup][warn] $*"; }
log_error() { red    "[cleanup][error] $*"; }
log_step()  { blue   "==== $* ===="; }

# ── Run directory management ─────────────────────────────────────────────────

init_run_dir() {
  local label="${1:-cleanup}"
  local ts
  ts="$(date +%s)"
  RUN_DIR="$PLATFORM_ROOT/tmp/e2e-cleanup-${label}-${ts}"
  mkdir -p "$RUN_DIR"/{reports,ids,backup,logs}
  echo "$RUN_DIR"
}

# ── SQL file generation ──────────────────────────────────────────────────────

write_sql_file() {
  local db_name="$1"
  local phase="$2"
  local content="$3"
  local file="$RUN_DIR/${db_name}_${phase}.sql"
  printf '%s\n' "$content" > "$file"
  log_info "Generated: $file"
  echo "$file"
}

# ── DB helper macros ─────────────────────────────────────────────────────────

# Builds a LIKE clause from a list of patterns joined with OR
build_like_clause() {
  local column="$1"
  shift
  local patterns=("$@")
  local first=true
  local result=""
  for p in "${patterns[@]}"; do
    if $first; then
      result="$column LIKE '${p}'"
      first=false
    else
      result="$result OR $column LIKE '${p}'"
    fi
  done
  echo "$result"
}

# Escapes single quotes for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Wraps value in single quotes for SQL
sql_quote() {
  printf "'%s'" "$(sql_escape "$1")"
}

# ── Validation ───────────────────────────────────────────────────────────────

require_env() {
  local var="$1"
  local desc="$2"
  if [[ -z "${!var:-}" ]]; then
    log_error "Missing required env var: $var ($desc)"
    log_info "Set it or export it before running this script."
    exit 1
  fi
}

# ── Report helpers ──────────────────────────────────────────────────────────

write_report_header() {
  local report="$1"
  local title="$2"
  cat > "$report" <<EOF
# Bazaar E2E Cleanup — $title

- Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Run directory: $RUN_DIR

EOF
}

write_report_section() {
  local report="$1"
  local section="$2"
  printf '\n## %s\n\n' "$section" >> "$report"
}

write_report_row() {
  local report="$1"
  local table="$2"
  local count="$3"
  local extra="${4:-}"
  printf '| `%s` | %s | %s |\n' "$table" "$count" "$extra" >> "$report"
}

# ── ID file management ──────────────────────────────────────────────────────

write_id_list() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
  log_info "Saved $(wc -l < "$file" | tr -d ' ') IDs to $file"
}

read_id_list() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    log_warn "ID file not found: $file"
  fi
}

# ── Dry-run standard header ─────────────────────────────────────────────────

dry_run_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║          E2E CLEANUP — DRY RUN ONLY                         ║
║                                                            ║
║  This script performs SELECT queries ONLY.                 ║
║  NO data will be modified or deleted.                      ║
║                                                            ║
║  Review the generated reports before running apply.        ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

# ── Apply safety banner ─────────────────────────────────────────────────────

apply_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║          E2E CLEANUP — APPLY MODE                           ║
║                                                            ║
║  This script WILL DELETE data from Render databases.       ║
║  Ensure you have:                                          ║
║    1. Reviewed the dry-run report                          ║
║    2. Verified backup was created                          ║
║    3. Set the confirmation flag                            ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

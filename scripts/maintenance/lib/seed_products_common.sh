#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar Render Seed Products — Common Library
#
# Shared functions for:
#   seed_render_products.sh
#   delete_render_seed_products.sh
#
# Sources cleanup_e2e_common.sh for colors, logging, env loading, and
# PLATFORM_ROOT detection.
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
  mkdir -p "$RUN_DIR"/{logs,reports,http}
  SEED_HTTP_DIR="$RUN_DIR/http"
  mkdir -p "$SEED_HTTP_DIR"
  echo "$RUN_DIR"
}

# ── Banners ───────────────────────────────────────────────────────────────────

seed_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║     RENDER SEED — POPULATE DEMO PRODUCTS                    ║
║                                                            ║
║  CREATES demo products via the API gateway.                ║
║  Target:  Render Gateway  (RENDER_API_BASE_URL)            ║
║  Batch:   ${RENDER_SEED_BATCH_ID:-<auto>}                         ║
║  Count:   ${SEED_PRODUCTS_COUNT:-50}                               ║
║  Seller:  ${SEED_SELLER_EMAIL:-<env var>}                     ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

delete_seed_banner() {
  cat <<BANNER

╔══════════════════════════════════════════════════════════════╗
║     RENDER SEED — DELETE DEMO PRODUCTS                      ║
║                                                            ║
║  DELETES seed products via the API gateway.                ║
║  Target:  Render Gateway  (RENDER_API_BASE_URL)            ║
║  Batch:   ${RENDER_SEED_BATCH_ID:-<ALL batches>}                  ║
║  Seller:  ${SEED_SELLER_EMAIL:-<env var>}                     ║
╚══════════════════════════════════════════════════════════════╝

BANNER
}

delete_final_warning() {
  cat <<WARN

╔══════════════════════════════════════════════════════════════╗
║  FINAL WARNING: This will DELETE data from Render.          ║
║  Review the preview above carefully.                        ║
║  A JSON backup will be saved to the run directory.          ║
╚══════════════════════════════════════════════════════════════╝

WARN
}

# ── Validation ───────────────────────────────────────────────────────────────

check_curl() {
  if ! command -v curl &>/dev/null; then
    red "[seed][error]  curl is not installed or not in PATH."
    log_info "Install it: brew install curl (macOS) or apt install curl (Linux)"
    exit 1
  fi
}

require_api_base_url() {
  if [[ -z "${RENDER_API_BASE_URL:-}" ]]; then
    red "[seed][error]  RENDER_API_BASE_URL is not set."
    log_info "Set it via scripts/maintenance/.env.cleanup or export RENDER_API_BASE_URL"
    exit 1
  fi
  log_info "RENDER_API_BASE_URL: [set]"
}

require_seed_seller() {
  require_env "SEED_SELLER_EMAIL" "seller email for authentication"
  require_env "SEED_SELLER_PASSWORD" "seller password for authentication"
}

# ── JSON extraction (using python3, consistent with e2e suite) ────────────────

seed_json_get() {
  local file="$1"
  local expr="$2"

  python3 - "$file" "$expr" <<'PY'
import json, sys

file_path = sys.argv[1]
expr = sys.argv[2].strip()

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

if expr.startswith("."):
    expr = expr[1:]

cur = data
for part in expr.split("."):
    if not part:
        continue
    if isinstance(cur, dict):
        cur = cur.get(part, "")
    elif isinstance(cur, list) and part.lstrip("-").isdigit():
        idx = int(part)
        if 0 <= idx < len(cur):
            cur = cur[idx]
        else:
            cur = ""
            break
    else:
        cur = ""
        break

if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
PY
}

# ── API HTTP request ──────────────────────────────────────────────────────────

#
# seed_api_req <label> <method> <path> [payload] [idempotency_key]
#
# Makes an authenticated API request to RENDER_API_BASE_URL + path.
# Response body → $SEED_HTTP_DIR/<label>.json
# HTTP code   → $SEED_HTTP_DIR/<label>.code (also returned on stdout)
#
seed_api_req() {
  local label="$1"
  local method="$2"
  local path="$3"
  local payload="${4:-}"
  local idempotency_key="${5:-}"

  local url="${RENDER_API_BASE_URL}${path}"
  local body_file="$SEED_HTTP_DIR/${label}.json"
  local code_file="$SEED_HTTP_DIR/${label}.code"

  local args=(curl -sS -X "$method" "$url" -o "$body_file" -w '%{http_code}' -H "Accept: application/json")

  if [[ -n "${SEED_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${SEED_TOKEN}")
  fi

  if [[ -n "$payload" ]]; then
    args+=(-H "Content-Type: application/json" --data "$payload")
  fi

  if [[ -n "$idempotency_key" ]]; then
    args+=(-H "Idempotency-Key: ${idempotency_key}")
  fi

  # Log the request (masked)
  {
    echo "${method} ${url}"
    echo "Authorization: Bearer ***"
    [[ -n "$payload" ]] && echo "BODY: $(mask_seed_body "$payload")"
    [[ -n "$idempotency_key" ]] && echo "Idempotency-Key: ${idempotency_key}"
  } >"$SEED_HTTP_DIR/${label}.request.txt"

  local code
  code="$("${args[@]}" 2>/dev/null || printf "000")"
  printf '%s' "$code" >"$code_file"
  printf '%s' "$code"
}

mask_seed_body() {
  printf '%s\n' "$1" | sed 's/"password":"[^"]*"/"password":"***"/g'
}

# ── Authentication ────────────────────────────────────────────────────────────

#
# seed_login
#
# Authenticates with SEED_SELLER_EMAIL / SEED_SELLER_PASSWORD via the
# auth service login endpoint.
#
# On success, exports: SEED_TOKEN, SEED_SELLER_ID
# On failure, exits with error and clear message.
#
seed_login() {
  local email="${SEED_SELLER_EMAIL:-}"
  local password="${SEED_SELLER_PASSWORD:-}"

  if [[ -z "$email" || -z "$password" ]]; then
    red "[seed][error]  SEED_SELLER_EMAIL and SEED_SELLER_PASSWORD must be set."
    log_info "Provide them via environment:"
    log_info "  export SEED_SELLER_EMAIL=\"seller@example.com\""
    log_info "  export SEED_SELLER_PASSWORD=\"...\""
    exit 1
  fi

  log_info "Authenticating seller: ${email}"

  local payload
  payload="$(python3 - "$email" "$password" <<'PY'
import json, sys
print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))
PY
  )"

  local code
  code="$(seed_api_req "seed-login" POST "/auth/login" "$payload")"

  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    red "[seed][error]  Authentication failed with HTTP $code"
    local body
    body="$(cat "$SEED_HTTP_DIR/seed-login.json" 2>/dev/null || echo "")"
    log_info "Response: ${body:0:500}"
    log_info "Check that SEED_SELLER_EMAIL and SEED_SELLER_PASSWORD are correct."
    log_info "Also ensure the user is registered with a 'seller' role."
    exit 1
  fi

  SEED_TOKEN="$(seed_json_get "$SEED_HTTP_DIR/seed-login.json" "access_token")"

  if [[ -z "$SEED_TOKEN" ]]; then
    red "[seed][error]  Login succeeded but no access_token found in response."
    log_info "Full response: $(cat "$SEED_HTTP_DIR/seed-login.json" 2>/dev/null)"
    exit 1
  fi

  # Try multiple fields for user ID (varies by service version)
  local seller_id
  seller_id="$(seed_json_get "$SEED_HTTP_DIR/seed-login.json" "user_id")"
  [[ -z "$seller_id" ]] && seller_id="$(seed_json_get "$SEED_HTTP_DIR/seed-login.json" "id")"
  [[ -z "$seller_id" ]] && seller_id="$(seed_json_get "$SEED_HTTP_DIR/seed-login.json" "user.id")"

  local seller_name
  seller_name="$(seed_json_get "$SEED_HTTP_DIR/seed-login.json" "username")"

  export SEED_TOKEN SEED_SELLER_ID="${seller_id}" SEED_SELLER_USERNAME="${seller_name:-unknown}"

  log_info "Authenticated. seller_id=${seller_id:-?} username=${seller_name:-?}"
  return 0
}

# ── Product helpers (API-based) ───────────────────────────────────────────────

#
# seed_product_name_prefix <batch_id>
#
# Returns the name prefix used to identify seed products in list responses.
#
seed_product_name_prefix() {
  local batch="${1:-}"
  if [[ -n "$batch" ]]; then
    echo "RENDER_SEED_PRODUCT_${batch}"
  else
    echo "RENDER_SEED_PRODUCT_"
  fi
}

#
# seed_find_product_ids_by_prefix <json_file> <prefix>
#
# Scans a catalog list JSON response for products whose name starts with
# the given prefix. Outputs one product ID per line.
#
seed_find_product_ids_by_prefix() {
  local file="$1"
  local prefix="$2"

  python3 - "$file" "$prefix" <<'PY'
import json, sys

file_path = sys.argv[1]
prefix = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

# Extract product list from response
products = []
if isinstance(data, list):
    products = data
elif isinstance(data, dict):
    for key in ("products", "items", "data"):
        val = data.get(key)
        if isinstance(val, list):
            products = val
            break
    # Sometimes the data is wrapped: {"data": {"products": [...]}}
    if not products and isinstance(data.get("data"), dict):
        for key in ("products", "items"):
            val = data["data"].get(key)
            if isinstance(val, list):
                products = val
                break

for p in products:
    if isinstance(p, dict):
        name = p.get("name", "")
        pid = p.get("id") or p.get("ID") or ""
        if name.startswith(prefix) and pid:
            print(pid)
PY
}

#
# seed_list_products_with_names <json_file> <prefix>
#
# Like seed_find_product_ids_by_prefix but outputs "id|name" for reporting.
#
seed_list_products_with_names() {
  local file="$1"
  local prefix="$2"

  python3 - "$file" "$prefix" <<'PY'
import json, sys

file_path = sys.argv[1]
prefix = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

products = []
if isinstance(data, list):
    products = data
elif isinstance(data, dict):
    for key in ("products", "items", "data"):
        val = data.get(key)
        if isinstance(val, list):
            products = val
            break
    if not products and isinstance(data.get("data"), dict):
        for key in ("products", "items"):
            val = data["data"].get(key)
            if isinstance(val, list):
                products = val
                break

for p in products:
    if isinstance(p, dict):
        name = p.get("name", "")
        pid = p.get("id") or p.get("ID") or ""
        if name.startswith(prefix) and pid:
            print("{}|{}".format(pid, name))
PY
}

#
# seed_count_products_by_prefix <json_file> <prefix>
#
seed_count_products_by_prefix() {
  local file="$1"
  local prefix="$2"
  seed_find_product_ids_by_prefix "$file" "$prefix" | wc -l | tr -d ' '
}

#
# seed_fetch_all_products <label_base>
#
# Fetches all products for the authenticated seller, handling pagination.
# Saves each page to $SEED_HTTP_DIR/<label_base>-p<page>.json
# Returns the number of pages fetched.
#
seed_fetch_all_products() {
  local label_base="$1"
  local max_pages="${2:-10}"
  local page_size="${3:-100}"
  local page=1

  while [[ $page -le $max_pages ]]; do
    seed_api_req "${label_base}-p${page}" GET \
      "/catalog/me/products?page=${page}&page_size=${page_size}" >/dev/null

    local code
    code="$(cat "$SEED_HTTP_DIR/${label_base}-p${page}.code" 2>/dev/null)"

    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
      # Stop on first non-2xx page (end of data or error)
      break
    fi

    local total_pages
    total_pages="$(seed_json_get "$SEED_HTTP_DIR/${label_base}-p${page}.json" "total_pages")"
    total_pages="${total_pages:-1}"

    if [[ "$page" -ge "$total_pages" ]]; then
      echo "$page"
      return 0
    fi

    page=$((page + 1))
  done

  echo "$((page - 1))"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

is_2xx() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }
is_4xx() { [[ "$1" =~ ^4[0-9][0-9]$ ]]; }

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
    log_info "This script WRITES data to Render via the API. It will not run without explicit confirmation."
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
    log_info "This script DELETES data from Render via the API. It will not run without explicit confirmation."
    log_info ""
    log_info "Usage:"
    log_info "  CONFIRMATION=\"$required\" ./scripts/maintenance/delete_render_seed_products.sh"
    log_info ""
    log_info "Dry-run (no confirmation needed):"
    log_info "  DRY_RUN=true ./scripts/maintenance/delete_render_seed_products.sh"
    exit 1
  fi
}

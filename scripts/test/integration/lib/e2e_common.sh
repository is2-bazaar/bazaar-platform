#!/usr/bin/env bash
# e2e_common.sh — Shared initialization and helpers for the Bazaar E2E suite.
# Sources: scripts/common.sh
# Must be sourced before any other e2e_*.sh lib.

[[ -n "${_E2E_COMMON_SOURCED:-}" ]] && return 0
_E2E_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLATFORM_ROOT="${PLATFORM_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LIB_DIR="$SCRIPT_DIR/lib"

# ---------------------------------------------------------------------------
# Load platform environment
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$PLATFORM_ROOT/scripts/common.sh"
load_platform_env

# ---------------------------------------------------------------------------
# Service URL defaults (wrappers override these before sourcing)
# ---------------------------------------------------------------------------
API_BASE="${API_BASE:-http://localhost:8080}"
AUTH_BASE="${AUTH_BASE:-http://localhost:${AUTH_SERVICE_HOST_PORT:-18081}}"
USER_BASE="${USER_BASE:-http://localhost:${USER_SERVICE_HOST_PORT:-18082}}"
CATALOG_BASE="${CATALOG_BASE:-http://localhost:${CATALOG_SERVICE_HOST_PORT:-18083}}"
CART_BASE="${CART_BASE:-http://localhost:${CART_SERVICE_HOST_PORT:-18085}}"
ORDER_BASE="${ORDER_BASE:-http://localhost:${ORDER_SERVICE_HOST_PORT:-18086}}"
PAYMENT_BASE="${PAYMENT_BASE:-http://localhost:${PAYMENT_SERVICE_HOST_PORT:-18084}}"

# ---------------------------------------------------------------------------
# Load local env vars
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
  source "$PLATFORM_ROOT/.env.local"
fi

# ---------------------------------------------------------------------------
# Resolve admin credentials
# ---------------------------------------------------------------------------
_resolve_admin_creds() {
  if [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    echo "[e2e] Using ADMIN_EMAIL/ADMIN_PASSWORD from environment"
    return 0
  fi

  local bootstrap_value="${AUTH_BOOTSTRAP_ADMINS:-}"

  if [[ -n "$bootstrap_value" ]]; then
    local stripped_value="$bootstrap_value"
    if [[ "$stripped_value" == \'*\' ]]; then
      stripped_value="${stripped_value#\'}"
      stripped_value="${stripped_value%\'}"
    elif [[ "$stripped_value" == \"*\" ]]; then
      stripped_value="${stripped_value#\"}"
      stripped_value="${stripped_value%\"}"
    fi

    local email password

    # Try JSON first (properly quoted keys and values)
    email="$(echo "$stripped_value" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('email', ''))
except Exception:
    pass
" 2>/dev/null)"

    password="$(echo "$stripped_value" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('password', ''))
except Exception:
    pass
" 2>/dev/null)"

    # Fallback: unquoted JS-object format
    if [[ -z "$email" || -z "$password" ]]; then
      email="$(echo "$stripped_value" | grep -oE 'email:[[:space:]]*([^,[:space:]}]+)' | head -1 | sed -E 's/^email:[[:space:]]*//')"
      password="$(echo "$stripped_value" | grep -oE 'password:[[:space:]]*([^,[:space:]}]+)' | head -1 | sed -E 's/^password:[[:space:]]*//')"
    fi

    if [[ -n "$email" && -n "$password" ]]; then
      ADMIN_EMAIL="$email"
      ADMIN_PASSWORD="$password"
      echo "[e2e] Resolved admin from AUTH_BOOTSTRAP_ADMINS: $ADMIN_EMAIL"
      return 0
    fi
  fi

  echo "[e2e][warn] Admin credentials not found. Set ADMIN_EMAIL/ADMIN_PASSWORD or AUTH_BOOTSTRAP_ADMINS. Admin tests will be skipped."
  ADMIN_EMAIL=""
  ADMIN_PASSWORD=""
  return 0
}

# ---------------------------------------------------------------------------
# Global defaults
# ---------------------------------------------------------------------------
INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"
PASSWORD="${PASSWORD:-E2eUser1234!}"
RUN_ID="${RUN_ID:-$(date +%s)}"

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
OUT_DIR="tmp/e2e-${E2E_TARGET_ENV:-local}-${RUN_ID}"
HTTP_DIR="$OUT_DIR/http"
STATE_DIR="$OUT_DIR/state"
REPORT="$OUT_DIR/REPORT.md"
RESULTS="$OUT_DIR/results.tsv"
TMP_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$HTTP_DIR" "$STATE_DIR"
: >"$RESULTS"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
USER_SEQ=0

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue() { printf "\033[34m%s\033[0m\n" "$*"; }

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------
record() {
  local status="$1"
  local name="$2"
  local note="${3:-}"
  printf "%s\t%s\t%s\n" "$status" "$name" "$note" >>"$RESULTS"

  case "$status" in
    PASS) PASS=$((PASS + 1)) && green "PASS - $name - $note" ;;
    FAIL) FAIL=$((FAIL + 1)) && red "FAIL - $name - $note" ;;
    SKIP) SKIP=$((SKIP + 1)) && yellow "SKIP - $name - $note" ;;
  esac
}

# ---------------------------------------------------------------------------
# State store
# ---------------------------------------------------------------------------
state_put() { printf '%s' "$2" >"$STATE_DIR/$1"; }
state_get() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1" || true; }

# ---------------------------------------------------------------------------
# Report writer
# ---------------------------------------------------------------------------
write_report() {
  {
    echo "# Bazaar E2E — Modular Suite"
    echo ""
    echo "- RUN_ID: $RUN_ID"
    echo "- TARGET_ENV: ${E2E_TARGET_ENV:-local}"
    echo "- API_BASE: $API_BASE"
    echo "- CART_BASE: $CART_BASE"
    echo "- ORDER_BASE: $ORDER_BASE"
    echo "- PAYMENT_BASE: $PAYMENT_BASE"
    echo "- OUT_DIR: $OUT_DIR"
    echo ""
    echo "## Results"
    echo ""
    echo "| Estado | Caso | Notas |"
    echo "|---|---|---|"
    while IFS=$'\t' read -r s name note; do
      echo "| $s | $name | $note |"
    done <"$RESULTS"
    echo ""
    echo "## Summary"
    echo ""
    echo "- PASS: $PASS"
    echo "- FAIL: $FAIL"
    echo "- SKIP: $SKIP"
    echo ""
    echo "## Raw"
    echo ""
    echo "$HTTP_DIR"
  } >"$REPORT"
}

# ---------------------------------------------------------------------------
# Init function — call once from orchestrator
# ---------------------------------------------------------------------------
e2e_common_init() {
  _resolve_admin_creds

  # Re-export so subshells and later sourcing pick up resolved values
  export ADMIN_EMAIL ADMIN_PASSWORD
  export API_BASE AUTH_BASE USER_BASE CATALOG_BASE CART_BASE ORDER_BASE PAYMENT_BASE
  export INTERNAL_SERVICE_TOKEN CART_INTERNAL_SERVICE_TOKEN
  export PASSWORD RUN_ID
  export OUT_DIR HTTP_DIR STATE_DIR REPORT RESULTS
  export PASS FAIL SKIP USER_SEQ

  blue "RUN_ID=$RUN_ID"
  blue "TARGET_ENV=${E2E_TARGET_ENV:-local}"
  blue "OUT_DIR=$OUT_DIR"
  blue "INTERNAL_TOKEN_LEN=${#INTERNAL_SERVICE_TOKEN}"
  blue "CART_INTERNAL_TOKEN_LEN=${#CART_INTERNAL_SERVICE_TOKEN}"
}

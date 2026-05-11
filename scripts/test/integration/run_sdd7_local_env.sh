#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
source "$PLATFORM_ROOT/scripts/common.sh"
load_platform_env

export E2E_TARGET_ENV="local"
export API_BASE="${API_BASE:-$LOCAL_API_BASE_URL}"
export AUTH_BASE="${AUTH_BASE:-http://localhost:${AUTH_SERVICE_HOST_PORT:-18081}}"
export USER_BASE="${USER_BASE:-http://localhost:${USER_SERVICE_HOST_PORT:-18082}}"
export CATALOG_BASE="${CATALOG_BASE:-http://localhost:${CATALOG_SERVICE_HOST_PORT:-18083}}"
export PAYMENT_BASE="${PAYMENT_BASE:-http://localhost:${PAYMENT_SERVICE_HOST_PORT:-18084}}"
export CART_BASE="${CART_BASE:-http://localhost:${CART_SERVICE_HOST_PORT:-18085}}"
export ORDER_BASE="${ORDER_BASE:-http://localhost:${ORDER_SERVICE_HOST_PORT:-18086}}"
export INTERNAL_SERVICE_TOKEN="${INTERNAL_SERVICE_TOKEN:-}"
export CART_INTERNAL_SERVICE_TOKEN="${CART_INTERNAL_SERVICE_TOKEN:-$INTERNAL_SERVICE_TOKEN}"
export PAYMENT_SIMULATION_MODE="approved"

# ── Resolve admin credentials ──────────────────────────────────────────────
_resolve_admin_creds() {
  # Already set in environment → use those
  if [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    echo "[sdd7-sdd8-sdd9][local] Using ADMIN_EMAIL/ADMIN_PASSWORD from environment"
    export ADMIN_EMAIL ADMIN_PASSWORD
    return 0
  fi

  local auth_env_file=""
  local auth_root="$BAZAAR_AUTH_SERVICE_PATH"

  if [[ -f "$auth_root/.env.local" ]]; then
    auth_env_file="$auth_root/.env.local"
  elif [[ -f "$auth_root/.env" ]]; then
    auth_env_file="$auth_root/.env"
  fi

  if [[ -z "$auth_env_file" ]]; then
    echo "[checkout-saga][local][error] Missing admin credentials. Set ADMIN_EMAIL/ADMIN_PASSWORD or AUTH_BOOTSTRAP_ADMINS in auth-service env."
    exit 1
  fi

  # Extract AUTH_BOOTSTRAP_ADMINS JSON from auth env file.
  # Render and some local setups may wrap the value in external quotes (single or double).
  # We strip those before passing to Python's json.loads.
  local bootstrap_value
  bootstrap_value="$(grep -E '^AUTH_BOOTSTRAP_ADMINS=' "$auth_env_file" | head -1 | sed 's/^AUTH_BOOTSTRAP_ADMINS=//')"

  if [[ -z "$bootstrap_value" ]]; then
    echo "[checkout-saga][local][error] Missing admin credentials. Set ADMIN_EMAIL/ADMIN_PASSWORD or AUTH_BOOTSTRAP_ADMINS in auth-service env."
    exit 1
  fi

  # Strip external quotes if present (e.g. '[...]' or "[...]")
  local stripped_value="$bootstrap_value"
  if [[ "$stripped_value" == \'*\' ]]; then
    stripped_value="${stripped_value#\'}"
    stripped_value="${stripped_value%\'}"
  elif [[ "$stripped_value" == \"*\" ]]; then
    stripped_value="${stripped_value#\"}"
    stripped_value="${stripped_value%\"}"
  fi

  # Parse the first admin entry: email + password
  # Uses stripped_value (external quotes already removed) for safe JSON parsing.
  local email password
  email="$(echo "$stripped_value" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if isinstance(data, list) and len(data) > 0:
    print(data[0].get('email', ''))
" 2>/dev/null)"

  password="$(echo "$stripped_value" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if isinstance(data, list) and len(data) > 0:
    print(data[0].get('password', ''))
" 2>/dev/null)"

  if [[ -z "$email" || -z "$password" ]]; then
    echo "[checkout-saga][local][error] Missing admin credentials. Set ADMIN_EMAIL/ADMIN_PASSWORD or AUTH_BOOTSTRAP_ADMINS in auth-service env."
    exit 1
  fi

  export ADMIN_EMAIL="$email"
  export ADMIN_PASSWORD="$password"
  echo "[sdd7-sdd8-sdd9][local] Resolved admin from $auth_env_file: $ADMIN_EMAIL"
}

_resolve_admin_creds

echo "[sdd7-sdd8-sdd9][local] Using local platform URLs"
echo "[sdd7-sdd8-sdd9][local] API_BASE=$API_BASE"
echo "[sdd7-sdd8-sdd9][local] ORDER_BASE=$ORDER_BASE"

"$SCRIPT_DIR/e2e_render_checkout_saga_sdd7.sh"

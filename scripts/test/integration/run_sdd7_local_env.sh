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

echo "[sdd7][local] Using local platform URLs"
echo "[sdd7][local] API_BASE=$API_BASE"
echo "[sdd7][local] ORDER_BASE=$ORDER_BASE"

"$SCRIPT_DIR/e2e_render_checkout_saga_sdd7.sh"

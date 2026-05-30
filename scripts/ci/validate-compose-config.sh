#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}

trap cleanup EXIT

create_stub_repo() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.20
CMD ["true"]
DOCKERFILE
}

create_stub_runtime_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts/dev"
  local script_name
  for script_name in up down status; do
    cat >"$dir/scripts/dev/${script_name}.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$dir/scripts/dev/${script_name}.sh"
  done
}

create_stub_repo "$TMP_ROOT/Bazaar-backend-api-gateway"
create_stub_repo "$TMP_ROOT/bazaar-backend-auth-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-cart-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-catalog-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-order-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-payment-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-recommendation-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-user-service"

create_stub_runtime_repo "$TMP_ROOT/bazaar-backoffice"
create_stub_runtime_repo "$TMP_ROOT/bazaar-mobile"

touch "$TMP_ROOT/bazaar-backoffice/package-lock.json"
touch "$TMP_ROOT/bazaar-mobile/package-lock.json"
mkdir -p "$TMP_ROOT/bazaar-backoffice/node_modules" "$TMP_ROOT/bazaar-mobile/node_modules"

cd "$REPO_ROOT"

# shellcheck disable=SC2016
env \
  BAZAAR_API_GATEWAY_PATH="$TMP_ROOT/Bazaar-backend-api-gateway" \
  BAZAAR_AUTH_SERVICE_PATH="$TMP_ROOT/bazaar-backend-auth-service" \
  BAZAAR_CART_SERVICE_PATH="$TMP_ROOT/bazaar-backend-cart-service" \
  BAZAAR_CATALOG_SERVICE_PATH="$TMP_ROOT/bazaar-backend-catalog-service" \
  BAZAAR_ORDER_SERVICE_PATH="$TMP_ROOT/bazaar-backend-order-service" \
  BAZAAR_PAYMENT_SERVICE_PATH="$TMP_ROOT/bazaar-backend-payment-service" \
  BAZAAR_RECOMMENDATION_SERVICE_PATH="$TMP_ROOT/bazaar-backend-recommendation-service" \
  BAZAAR_USER_SERVICE_PATH="$TMP_ROOT/bazaar-backend-user-service" \
  BAZAAR_BACKOFFICE_PATH="$TMP_ROOT/bazaar-backoffice" \
  BAZAAR_MOBILE_PATH="$TMP_ROOT/bazaar-mobile" \
  COMPOSE_OUTPUT="$TMP_ROOT/compose.yml" \
  bash -lc '
    set -euo pipefail
    source scripts/common.sh
    load_platform_env
    platform_backend_select_stack
    ALLOW_EXPO_RETURN_URLS=true
    platform_compose config >"$COMPOSE_OUTPUT"
  '

grep -q 'ALLOW_EXPO_RETURN_URLS: "true"' "$TMP_ROOT/compose.yml" || {
  echo "orders-service does not receive ALLOW_EXPO_RETURN_URLS" >&2
  exit 1
}

echo "compose config ok"

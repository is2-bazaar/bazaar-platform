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
  cat >"$dir/Dockerfile" <<'EOF'
FROM alpine:3.20
CMD ["true"]
EOF
}

create_stub_runtime_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts/dev"
  local script_name
  for script_name in up down status; do
    cat >"$dir/scripts/dev/${script_name}.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/scripts/dev/${script_name}.sh"
  done
}

create_stub_repo "$TMP_ROOT/Bazaar-backend-api-gateway"
create_stub_repo "$TMP_ROOT/bazaar-backend-auth-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-user-service"
create_stub_repo "$TMP_ROOT/bazaar-backend-catalog-service"

mkdir -p \
  "$TMP_ROOT/bazaar-backend/services/inventory-service" \
  "$TMP_ROOT/bazaar-backend/services/cart-service" \
  "$TMP_ROOT/bazaar-backend/services/orders-service" \
  "$TMP_ROOT/bazaar-backend/services/payments-service" \
  "$TMP_ROOT/bazaar-backend/services/notifications-service"

create_stub_repo "$TMP_ROOT/bazaar-backend/services/inventory-service"
create_stub_repo "$TMP_ROOT/bazaar-backend/services/cart-service"
create_stub_repo "$TMP_ROOT/bazaar-backend/services/orders-service"
create_stub_repo "$TMP_ROOT/bazaar-backend/services/payments-service"
create_stub_repo "$TMP_ROOT/bazaar-backend/services/notifications-service"

create_stub_runtime_repo "$TMP_ROOT/bazaar-backoffice"
create_stub_runtime_repo "$TMP_ROOT/bazaar-mobile"

touch "$TMP_ROOT/bazaar-backoffice/package-lock.json"
touch "$TMP_ROOT/bazaar-mobile/package-lock.json"
mkdir -p "$TMP_ROOT/bazaar-backoffice/node_modules" "$TMP_ROOT/bazaar-mobile/node_modules"

cd "$REPO_ROOT"

env \
  BAZAAR_BACKEND_PATH="$TMP_ROOT/bazaar-backend" \
  BAZAAR_API_GATEWAY_PATH="$TMP_ROOT/Bazaar-backend-api-gateway" \
  BAZAAR_AUTH_SERVICE_PATH="$TMP_ROOT/bazaar-backend-auth-service" \
  BAZAAR_CATALOG_SERVICE_PATH="$TMP_ROOT/bazaar-backend-catalog-service" \
  BAZAAR_USER_SERVICE_PATH="$TMP_ROOT/bazaar-backend-user-service" \
  BAZAAR_BACKOFFICE_PATH="$TMP_ROOT/bazaar-backoffice" \
  BAZAAR_MOBILE_PATH="$TMP_ROOT/bazaar-mobile" \
  docker compose -f infra/compose/docker-compose.platform.yml config >/dev/null

echo "compose config ok"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ENV_FILE="$SCRIPT_DIR/.env.test"

if [[ ! -f "$TEST_ENV_FILE" ]]; then
  echo "[test:integration][error] no se encontro $TEST_ENV_FILE"
  exit 1
fi

if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
  echo "[test:integration][warn] .env.local existe y sera ignorado durante los tests"
fi

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  line="${line%%=*}"
  line="${line//[[:space:]]/}"
  [[ -n "$line" ]] && unset "$line"
done <"$TEST_ENV_FILE"

# shellcheck disable=SC1090
source "$TEST_ENV_FILE"

platform_test_info() {
  printf '[test:integration] %s\n' "$*"
}

platform_test_ok() {
  printf '[test:integration][ok] %s\n' "$*"
}

platform_test_fail() {
  printf '[test:integration][error] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || platform_test_fail "falta el comando requerido: $cmd"
}

resolve_to_absolute() {
  local var_name="$1"
  local value="${!var_name}"
  local abs
  abs="$(cd "$PLATFORM_ROOT" && realpath "$value" 2>/dev/null)" || abs="$value"
  printf -v "$var_name" '%s' "$abs"
}

platform_test_info "Iniciando suite de integration tests"
require_command node
platform_test_info "API base: $LOCAL_API_BASE_URL"
platform_test_info "Using JWT_SECRET configuration..."

PLATFORM_COMPOSE_FILE="$PLATFORM_ROOT/infra/compose/docker-compose.platform.yml"

platform_test_info "Verificando compose file..."
if ! docker compose -f "$PLATFORM_COMPOSE_FILE" config >/dev/null 2>&1; then
  platform_test_fail "docker compose no pudo procesar $PLATFORM_COMPOSE_FILE"
fi

platform_test_info "Verificando que los paths de los repos existan..."
for repo_var in BAZAAR_API_GATEWAY_PATH BAZAAR_AUTH_SERVICE_PATH BAZAAR_CART_SERVICE_PATH BAZAAR_CATALOG_SERVICE_PATH BAZAAR_ORDER_SERVICE_PATH BAZAAR_USER_SERVICE_PATH; do
  resolve_to_absolute "$repo_var"
  repo_path="${!repo_var}"
  if [[ ! -d "$repo_path" ]]; then
    platform_test_fail "repo no encontrado: $repo_var=$repo_path"
  fi
done

platform_test_info "Bajando stack existente (si hay)..."
docker compose -f "$PLATFORM_COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true

platform_test_info "Levantando stack de backend..."
BACKEND_STACK=full \
  BAZAAR_API_GATEWAY_PATH="$BAZAAR_API_GATEWAY_PATH" \
  BAZAAR_AUTH_SERVICE_PATH="$BAZAAR_AUTH_SERVICE_PATH" \
  BAZAAR_CART_SERVICE_PATH="$BAZAAR_CART_SERVICE_PATH" \
  BAZAAR_CATALOG_SERVICE_PATH="$BAZAAR_CATALOG_SERVICE_PATH" \
  BAZAAR_ORDER_SERVICE_PATH="$BAZAAR_ORDER_SERVICE_PATH" \
  BAZAAR_USER_SERVICE_PATH="$BAZAAR_USER_SERVICE_PATH" \
  INTERNAL_SERVICE_TOKEN="$INTERNAL_SERVICE_TOKEN" \
  AUTH_BOOTSTRAP_ADMINS="$AUTH_BOOTSTRAP_ADMINS" \
  CART_DB_NAME=cart_db \
  JWT_SECRET="$JWT_SECRET" \
  GATEWAY_LOGIN_RATE_LIMIT_MAX_REQUESTS=100 \
  AUTH_LOGIN_RATE_LIMIT_MAX_REQUESTS=100 \
  GATEWAY_ALLOWED_ORIGINS="" \
  GATEWAY_ENABLED_SERVICES="auth,user,catalog,cart,orders" \
  docker compose -f "$PLATFORM_COMPOSE_FILE" up --build -d \
  api-gateway \
  auth-service \
  user-service \
  catalog-service \
  cart-service \
  orders-service \
  auth-db \
  user-db \
  catalog-db \
  cart-db \
  orders-db

platform_test_info "Esperando readiness del gateway..."
MAX_WAIT=120
DEADLINE=$((SECONDS + MAX_WAIT))
while ((SECONDS < DEADLINE)); do
  if curl -sf "$LOCAL_API_BASE_URL/readyz" >/dev/null 2>&1; then
    platform_test_ok "Gateway ready"
    break
  fi

  EXITED=$(docker compose -f "$PLATFORM_COMPOSE_FILE" ps --services --status exited 2>/dev/null || true)
  if [[ -n "$EXITED" ]]; then
    platform_test_fail "Servicios caidos durante readiness: $EXITED"
  fi

  sleep 3
done

if ! curl -sf "$LOCAL_API_BASE_URL/readyz" >/dev/null 2>&1; then
  platform_test_fail "Gateway no respondio en ${MAX_WAIT}s"
fi

platform_test_info "Ejecutando suite de tests con node:test..."
node --test "$PLATFORM_ROOT/test/integration/harness-test.mjs" || {
  TEST_EXIT=$?
  platform_test_fail "Suite de tests fallida (exit $TEST_EXIT)"
  docker compose -f "$PLATFORM_COMPOSE_FILE" logs --tail=100 api-gateway 2>/dev/null || true
  exit $TEST_EXIT
}

platform_test_ok "Todos los tests pasaron"
platform_test_info "Limpiando stack de test..."
docker compose -f "$PLATFORM_COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
platform_test_ok "Stack limpiado"

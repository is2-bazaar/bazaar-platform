#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

require_command docker
require_command curl
require_command node
require_command npm

if ! docker compose version >/dev/null 2>&1; then
  platform_fail "docker compose no esta disponible"
fi

platform_ok "docker, docker compose, node, npm y curl disponibles"
platform_ok "defaults cargados correctamente"

require_env ENV_NAME
require_env BACKEND_PROVIDER
require_env DATABASE_PROVIDER
require_env BACKOFFICE_PROVIDER
require_env MOBILE_RUNTIME_MODE
require_env MOBILE_API_BASE_URL
require_env MOBILE_DEV_URL

if [[ "$ENV_NAME" != "local" ]]; then
  platform_fail "ENV_NAME debe ser local para el runtime ejecutable de bazaar-platform"
fi

platform_ok "ENV_NAME local detectado (ENV_NAME=$ENV_NAME)"

[[ -d "$BAZAAR_BACKEND_PATH" ]] || platform_fail "no se encontro bazaar-backend en $BAZAAR_BACKEND_PATH"
[[ -d "$BAZAAR_BACKOFFICE_PATH" ]] || platform_fail "no se encontro bazaar-backoffice en $BAZAAR_BACKOFFICE_PATH"
[[ -d "$BAZAAR_MOBILE_PATH" ]] || platform_fail "no se encontro bazaar-mobile en $BAZAAR_MOBILE_PATH"

[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/up.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/up.sh"
[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/down.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/down.sh"
[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/status.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/status.sh"
[[ -f "$BAZAAR_BACKOFFICE_PATH/scripts/dev/up.sh" ]] || platform_fail "falta $BAZAAR_BACKOFFICE_PATH/scripts/dev/up.sh"
[[ -f "$BAZAAR_BACKOFFICE_PATH/scripts/dev/down.sh" ]] || platform_fail "falta $BAZAAR_BACKOFFICE_PATH/scripts/dev/down.sh"
[[ -f "$BAZAAR_BACKOFFICE_PATH/scripts/dev/status.sh" ]] || platform_fail "falta $BAZAAR_BACKOFFICE_PATH/scripts/dev/status.sh"
[[ -f "$BAZAAR_MOBILE_PATH/scripts/dev/up.sh" ]] || platform_fail "falta $BAZAAR_MOBILE_PATH/scripts/dev/up.sh"
[[ -f "$BAZAAR_MOBILE_PATH/scripts/dev/down.sh" ]] || platform_fail "falta $BAZAAR_MOBILE_PATH/scripts/dev/down.sh"
[[ -f "$BAZAAR_MOBILE_PATH/scripts/dev/status.sh" ]] || platform_fail "falta $BAZAAR_MOBILE_PATH/scripts/dev/status.sh"

platform_ok "repos y entrypoints locales detectados"

if [[ ! -d "$BAZAAR_BACKOFFICE_PATH/node_modules" ]]; then
  platform_warn "backoffice no tiene dependencias instaladas; ejecutar npm install en $BAZAAR_BACKOFFICE_PATH"
fi

if [[ ! -d "$BAZAAR_MOBILE_PATH/node_modules" ]]; then
  platform_warn "mobile no tiene dependencias instaladas; ejecutar npm install en $BAZAAR_MOBILE_PATH"
fi

platform_info "check completo"

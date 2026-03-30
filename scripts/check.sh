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

[[ -d "$BAZAAR_BACKEND_PATH" ]] || platform_fail "no se encontro bazaar-backend en $BAZAAR_BACKEND_PATH"
[[ -d "$BAZAAR_BACKOFFICE_PATH" ]] || platform_fail "no se encontro bazaar-backoffice en $BAZAAR_BACKOFFICE_PATH"

if [[ ! -d "$BAZAAR_MOBILE_PATH" ]]; then
  platform_warn "bazaar-mobile no fue encontrado en $BAZAAR_MOBILE_PATH"
else
  platform_ok "bazaar-mobile encontrado en $BAZAAR_MOBILE_PATH"
fi

[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/up.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/up.sh"
[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/down.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/down.sh"
[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/status.sh" ]] || platform_fail "falta $BAZAAR_BACKEND_PATH/scripts/dev/status.sh"
[[ -f "$BAZAAR_BACKOFFICE_PATH/package.json" ]] || platform_fail "falta package.json en bazaar-backoffice"

platform_ok "repos y entrypoints locales detectados"

if [[ ! -d "$BAZAAR_BACKOFFICE_PATH/node_modules" ]]; then
  platform_warn "backoffice no tiene dependencias instaladas; ejecutar npm install en $BAZAAR_BACKOFFICE_PATH"
fi

if [[ -f "$BAZAAR_BACKOFFICE_PATH/.env.local" ]]; then
  if grep -Eq '^VITE_API_BASE_URL=' "$BAZAAR_BACKOFFICE_PATH/.env.local"; then
    platform_ok "backoffice tiene VITE_API_BASE_URL configurado en .env.local"
  else
    platform_warn "existe .env.local en backoffice, pero no define VITE_API_BASE_URL"
  fi
else
  platform_warn "backoffice no tiene .env.local; backoffice.sh inyectara VITE_API_BASE_URL en runtime"
fi

if curl -fsS "$LOCAL_API_BASE_URL/livez" >/dev/null 2>&1; then
  platform_ok "gateway ya responde en $LOCAL_API_BASE_URL"
else
  platform_warn "gateway no responde todavia en $LOCAL_API_BASE_URL"
fi

platform_info "check completo"

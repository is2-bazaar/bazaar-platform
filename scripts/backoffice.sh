#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

[[ -d "$BAZAAR_BACKOFFICE_PATH" ]] || platform_fail "no se encontro bazaar-backoffice en $BAZAAR_BACKOFFICE_PATH"
[[ -f "$BAZAAR_BACKOFFICE_PATH/package.json" ]] || platform_fail "falta package.json en bazaar-backoffice"
[[ -d "$BAZAAR_BACKOFFICE_PATH/node_modules" ]] || platform_fail "backoffice no tiene dependencias instaladas; ejecutar npm install en $BAZAAR_BACKOFFICE_PATH"

if ! curl -fsS "$LOCAL_API_BASE_URL/livez" >/dev/null 2>&1; then
  platform_warn "el gateway no responde en $LOCAL_API_BASE_URL; el backoffice arrancara igual"
fi

platform_info "arrancando backoffice con VITE_API_BASE_URL=$LOCAL_API_BASE_URL"

cd "$BAZAAR_BACKOFFICE_PATH"
VITE_API_BASE_URL="$LOCAL_API_BASE_URL" npm run dev

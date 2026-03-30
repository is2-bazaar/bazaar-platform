#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

platform_info "backend path: $BAZAAR_BACKEND_PATH"
platform_info "backoffice path: $BAZAAR_BACKOFFICE_PATH"
platform_info "mobile path: $BAZAAR_MOBILE_PATH"
platform_info "api base url efectiva: $LOCAL_API_BASE_URL"
platform_info "backoffice dev url efectiva: $BACKOFFICE_DEV_URL"

if [[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/status.sh" ]]; then
  bash "$BAZAAR_BACKEND_PATH/scripts/dev/status.sh"
else
  platform_warn "no se encontro scripts/dev/status.sh en bazaar-backend"
fi

if http_probe "$LOCAL_API_BASE_URL/livez"; then
  platform_ok "gateway responde en $LOCAL_API_BASE_URL/livez"
else
  platform_warn "gateway no responde en $LOCAL_API_BASE_URL/livez"
fi

if http_probe "$LOCAL_API_BASE_URL/readyz"; then
  platform_ok "gateway responde en $LOCAL_API_BASE_URL/readyz"
else
  platform_warn "gateway no responde en $LOCAL_API_BASE_URL/readyz"
fi

if http_probe "$BACKOFFICE_DEV_URL"; then
  platform_ok "backoffice responde en $BACKOFFICE_DEV_URL"
else
  platform_warn "backoffice no responde en $BACKOFFICE_DEV_URL"
fi

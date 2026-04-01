#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

"$SCRIPT_DIR/check.sh"

platform_info "levantando backend local desde $BAZAAR_BACKEND_PATH"
platform_info "backend stack solicitado: ${BACKEND_STACK:-full}"
bash "$BAZAAR_BACKEND_PATH/scripts/dev/up.sh"

platform_info "esperando readiness del gateway en $LOCAL_API_BASE_URL/readyz"
if ! wait_for_ready "$LOCAL_API_BASE_URL/readyz" 60; then
  platform_fail "el gateway no quedo ready en el tiempo esperado"
fi

platform_ok "backend listo en $LOCAL_API_BASE_URL"
platform_info "siguiente paso: ./scripts/backoffice.sh"
platform_info "backoffice esperado en: $BACKOFFICE_DEV_URL"

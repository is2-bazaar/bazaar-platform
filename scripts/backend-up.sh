#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env
platform_backend_select_stack

"$SCRIPT_DIR/check.sh"

platform_info "levantando stack backend local desde $PLATFORM_COMPOSE_FILE"
platform_info "gateway repo: $BAZAAR_API_GATEWAY_PATH"
platform_info "stack seleccionado: ${BACKEND_STACK:-full}"
platform_info "rutas habilitadas en gateway: $PLATFORM_GATEWAY_ENABLED_SERVICES"
platform_compose up --build -d "${PLATFORM_COMPOSE_SERVICES[@]}"

platform_info "esperando readiness del gateway en $LOCAL_API_BASE_URL/readyz"
if ! platform_wait_for_ready "$LOCAL_API_BASE_URL/readyz" 90; then
  platform_fail "el gateway no quedo ready en el tiempo esperado"
fi

platform_ok "stack backend listo"
platform_info "api base url: $LOCAL_API_BASE_URL"
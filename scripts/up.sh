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

platform_info "levantando backoffice desde su contrato local"
platform_run_backoffice_script up.sh

platform_info "levantando mobile desde su contrato local"
platform_run_mobile_script up.sh

platform_ok "stack local listo"
platform_info "api base url: $LOCAL_API_BASE_URL"
platform_info "backoffice dev url: $BACKOFFICE_DEV_URL"
platform_info "mobile api base url efectiva: $(platform_mobile_effective_api_base_url)"
platform_info "mobile bundler configurado: $MOBILE_DEV_URL"
platform_info "mobile bundler efectivo: $(platform_mobile_effective_dev_url)"
if [[ -n "${PLATFORM_LAN_IP:-}" ]]; then
  platform_info "ip local detectada para dispositivo: $PLATFORM_LAN_IP"
  platform_info "mobile en dispositivo fisico usa API: $(platform_mobile_device_api_url)"
  platform_info "mobile en dispositivo fisico consulta Metro en: $(platform_mobile_device_probe_url)"
  platform_info "mobile en dispositivo fisico abre Expo Go con: $(platform_mobile_device_url)"
else
  platform_warn "no se pudo detectar una IP LAN automaticamente; si usas dispositivo fisico, defini PLATFORM_LAN_IP en .env.local"
fi

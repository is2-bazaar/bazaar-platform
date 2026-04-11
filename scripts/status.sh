#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env
platform_backend_select_stack

platform_info "backend path: $BAZAAR_BACKEND_PATH"
platform_info "api gateway path: $BAZAAR_API_GATEWAY_PATH"
platform_info "auth-service path: $BAZAAR_AUTH_SERVICE_PATH"
platform_info "backoffice path: $BAZAAR_BACKOFFICE_PATH"
platform_info "mobile path: $BAZAAR_MOBILE_PATH"
platform_info "compose file: $PLATFORM_COMPOSE_FILE"
platform_info "api base url efectiva: $LOCAL_API_BASE_URL"
platform_info "backoffice dev url efectiva: $BACKOFFICE_DEV_URL"
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
platform_info "backend stack solicitado: ${BACKEND_STACK:-full}"

platform_compose ps "${PLATFORM_COMPOSE_SERVICES[@]}"

if platform_http_probe "$LOCAL_API_BASE_URL/livez"; then
  platform_ok "gateway responde en $LOCAL_API_BASE_URL/livez"
else
  platform_warn "gateway no responde en $LOCAL_API_BASE_URL/livez"
fi

if platform_http_probe "$LOCAL_API_BASE_URL/readyz"; then
  platform_ok "gateway responde en $LOCAL_API_BASE_URL/readyz"
else
  platform_warn "gateway no responde en $LOCAL_API_BASE_URL/readyz"
fi

platform_run_backoffice_script status.sh
platform_run_mobile_script status.sh

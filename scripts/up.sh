#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

"$SCRIPT_DIR/check.sh"

platform_info "levantando backend desde su contrato local"
platform_run_backend_script up.sh

platform_info "levantando backoffice desde su contrato local"
platform_run_backoffice_script up.sh

platform_info "levantando mobile desde su contrato local"
platform_run_mobile_script up.sh

platform_ok "stack local listo"
platform_info "api base url: $LOCAL_API_BASE_URL"
platform_info "backoffice dev url: $BACKOFFICE_DEV_URL"
platform_info "mobile dev url: $MOBILE_DEV_URL"
if [[ -n "${PLATFORM_LAN_IP:-}" ]]; then
  platform_info "ip local detectada para dispositivo: $PLATFORM_LAN_IP"
  platform_info "mobile en dispositivo fisico usa API: $(platform_mobile_device_api_url)"
  platform_info "mobile en dispositivo fisico abre bundler en: $(platform_mobile_device_url)"
else
  platform_warn "no se pudo detectar una IP LAN automaticamente; si usas dispositivo fisico, defini PLATFORM_LAN_IP en .env.local"
fi

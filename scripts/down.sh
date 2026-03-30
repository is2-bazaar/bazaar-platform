#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

[[ -f "$BAZAAR_BACKEND_PATH/scripts/dev/down.sh" ]] || platform_fail "falta scripts/dev/down.sh en bazaar-backend"

platform_info "apagando backend local"
bash "$BAZAAR_BACKEND_PATH/scripts/dev/down.sh"
platform_ok "backend local apagado"
platform_info "si el backoffice sigue corriendo en foreground, cortalo con Ctrl+C"

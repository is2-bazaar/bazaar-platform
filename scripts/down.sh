#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env
platform_backend_select_stack

platform_info "apagando mobile local"
platform_run_mobile_script down.sh

platform_info "apagando backoffice local"
platform_run_backoffice_script down.sh

platform_info "apagando stack backend local"
platform_compose down

platform_ok "stack local apagado"

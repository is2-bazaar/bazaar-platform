#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env

platform_info "apagando mobile local"
platform_run_mobile_script down.sh

platform_info "apagando backoffice local"
platform_run_backoffice_script down.sh

platform_info "apagando backend local"
platform_run_backend_script down.sh

platform_ok "stack local apagado"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_platform_env
platform_require_repo_script "bazaar-backoffice" "$BAZAAR_BACKOFFICE_PATH" "up.sh"

platform_info "delegando arranque de backoffice a su contrato local"
platform_run_backoffice_script up.sh

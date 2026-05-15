#!/usr/bin/env bash
# cases/00_readiness.sh — Wake all services, verify readiness
# Dependencies: none (implicit — services must be up)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"

case_00_readiness() {
  blue "--- 00_readiness ---"
  wake_services
}

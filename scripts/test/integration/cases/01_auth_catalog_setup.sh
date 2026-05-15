#!/usr/bin/env bash
# cases/01_auth_catalog_setup.sh — Register all actors and create seed products
# Depends on: 00_readiness (services up)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_catalog.sh"

case_01_auth_catalog_setup() {
  blue "--- 01_auth_catalog_setup ---"
  auth_suite
  catalog_setup_suite
}

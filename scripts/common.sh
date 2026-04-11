#!/usr/bin/env bash

PLATFORM_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_LIB_DIR="$PLATFORM_COMMON_DIR/lib"

# shellcheck disable=SC1091
source "$PLATFORM_LIB_DIR/logging.sh"
# shellcheck disable=SC1091
source "$PLATFORM_LIB_DIR/network.sh"
# shellcheck disable=SC1091
source "$PLATFORM_LIB_DIR/env.sh"
# shellcheck disable=SC1091
source "$PLATFORM_LIB_DIR/compose.sh"
# shellcheck disable=SC1091
source "$PLATFORM_LIB_DIR/runtime.sh"

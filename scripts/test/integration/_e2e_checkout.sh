#!/usr/bin/env bash
# _e2e_checkout.sh — DEPRECATED thin wrapper
# This script is deprecated. Use e2e_tests.sh directly instead.

echo "[e2e][deprecated] _e2e_checkout.sh is deprecated. Use e2e_tests.sh directly." >&2
echo "[e2e][deprecated] Redirecting to e2e_tests.sh..." >&2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/e2e_tests.sh" "$@"

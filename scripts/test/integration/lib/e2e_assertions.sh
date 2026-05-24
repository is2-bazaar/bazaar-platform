#!/usr/bin/env bash
# e2e_assertions.sh — Assertion helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_json.sh

[[ -n "${_E2E_ASSERTIONS_SOURCED:-}" ]] && return 0
_E2E_ASSERTIONS_SOURCED=1

# ---------------------------------------------------------------------------
# assert_no_internal_fields — ensure response does NOT leak internal fields
# ---------------------------------------------------------------------------
assert_no_internal_fields() {
  local file="$1"
  local case_name="$2"

  local result
  result="$(
    python3 - "$file" <<'PY'
import json, sys
file_path = sys.argv[1]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        text = f.read()
except Exception:
    sys.exit(0)
forbidden = ["idempotency_key", "last_error", "cart_cleanup_status", "stock_reservation_id"]
found = set()

def walk(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in forbidden:
                found.add(key)
            walk(value)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

try:
    walk(json.loads(text))
except Exception:
    pass

if found:
    print("LEAKED: " + ", ".join(sorted(found)))
else:
    print("ok")
PY
  )"

  if [[ "$result" == "ok" ]]; then
    record PASS "no internal fields $case_name" "clean"
  else
    record FAIL "no internal fields $case_name" "$result"
  fi
}

# ---------------------------------------------------------------------------
# assert_forbidden_or_hidden — accept 403 OR 404 as valid isolation responses
# ---------------------------------------------------------------------------
assert_forbidden_or_hidden() {
  local code="$1"
  local case_name="$2"

  if [[ "$code" == "403" || "$code" == "404" ]]; then
    record PASS "$case_name" "HTTP $code (isolated)"
  else
    record FAIL "$case_name" "HTTP $code expected 403 or 404 body=$(body_flat "$HTTP_DIR/${case_name// /-}.json")"
  fi
}

# ---------------------------------------------------------------------------
# assert_status_unchanged — verify order status did NOT change after mutation attempt
# ---------------------------------------------------------------------------
assert_status_unchanged() {
  local file="$1"
  local expected_status="$2"
  local case_name="$3"

  local actual
  actual="$(json_order_status "$file")"
  if [[ "$actual" == "$expected_status" ]]; then
    record PASS "$case_name" "status unchanged: $actual"
  else
    record FAIL "$case_name" "status changed: expected=$expected_status actual=$actual"
  fi
}

# ---------------------------------------------------------------------------
# poll_until — repeatedly run a command until it succeeds or max attempts.
# Records PASS when condition becomes true, FAIL when not satisfied after max.
#
# Usage:
#   poll_until <label> <max_attempts> <sleep_seconds> <command...>
# Example:
#   poll_until "my-condition" 20 2 test "$(some_check)" = "expected"
# ---------------------------------------------------------------------------
poll_until() {
  local label="$1"
  local max_attempts="${2:-30}"
  local sleep_secs="${3:-2}"
  shift 3

  local i
  for ((i = 1; i <= max_attempts; i++)); do
    if "$@" 2>/dev/null; then
      record PASS "poll $label" "succeeded on attempt $i/$max_attempts"
      return 0
    fi
    yellow "POLL $label attempt $i/$max_attempts"
    sleep "$sleep_secs"
  done
  record FAIL "poll $label" "FAILED after $max_attempts attempts"
  return 1
}

# ---------------------------------------------------------------------------
# NEW assertions
# ---------------------------------------------------------------------------

# assert_http_2xx — record PASS if 2xx, FAIL otherwise
assert_http_2xx() {
  local code="$1"
  local case_name="$2"
  if is_2xx "$code"; then
    record PASS "$case_name" "HTTP $code"
  else
    record FAIL "$case_name" "HTTP $code expected 2xx"
  fi
}

# assert_http_4xx — record PASS if 4xx, FAIL otherwise
assert_http_4xx() {
  local code="$1"
  local case_name="$2"
  if is_4xx "$code"; then
    record PASS "$case_name" "HTTP $code"
  else
    record FAIL "$case_name" "HTTP $code expected 4xx"
  fi
}

# assert_json_field_present — check if a field exists anywhere in the response
assert_json_field_present() {
  local file="$1"
  local field="$2"
  local case_name="$3"
  local result
  result="$(json_field_exists "$file" "$field")"
  if [[ "$result" == "true" ]]; then
    record PASS "$case_name" "field '$field' present"
  else
    record FAIL "$case_name" "field '$field' missing"
  fi
}

# assert_json_field_present_any — check if ANY of the space-separated fields exist
assert_json_field_present_any() {
  local file="$1"
  local fields="$2"
  local case_name="$3"
  local matched=""
  for field in $fields; do
    if [[ "$(json_field_exists "$file" "$field")" == "true" ]]; then
      matched="$field"
      break
    fi
  done
  if [[ -n "$matched" ]]; then
    record PASS "$case_name" "field '$matched' present"
  else
    record FAIL "$case_name" "none of [$fields] present"
  fi
}

# assert_order_status — verify order status matches expected value
assert_order_status() {
  local file="$1"
  local expected_status="$2"
  local case_name="$3"
  local actual
  actual="$(json_order_status "$file")"
  if [[ "$actual" == "$expected_status" ]]; then
    record PASS "$case_name" "status=$actual"
  else
    record FAIL "$case_name" "expected=$expected_status actual=$actual"
  fi
}

# assert_cart_qty — verify cart quantity for a product
assert_cart_qty() {
  local label="$1"
  local product_id="$2"
  local expected_qty="$3"
  local case_name="$4"
  local actual
  actual="$(json_find_cart_quantity_by_product_id "$HTTP_DIR/cart-get-$label.json" "$product_id")"
  if [[ "$actual" == "$expected_qty" ]]; then
    record PASS "$case_name" "qty=$actual"
  else
    record FAIL "$case_name" "qty=$actual expected=$expected_qty"
  fi
}

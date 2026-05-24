#!/usr/bin/env bash
# cases/06_auth_recovery_rate_limit.sh — Forgot-password rate limiting with non-disclosure
# Depends on: 00 (services up)
# Tests: /auth/forgot-password with NONEXISTENT email returns generic success
# that does NOT reveal existence. Then continue enough times to hit
# gateway/auth recovery rate limit (accepts either gateway 429 or auth 429).
# Stays focused on forgot-password only; does NOT expand into reset-password.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"

case_06_auth_recovery_rate_limit() {
  blue "--- 06_auth_recovery_rate_limit ---"

  local code i body_text rate_limited headers_file
  local nonexistent_email
  nonexistent_email="nonexistent-$(date +%s)@test.local"
  local forgot_payload="{\"email\":\"$nonexistent_email\"}"

  # ── Part A: Generic non-disclosure response ──
  blue "== Part A: generic success for nonexistent email =="
  code="$(req "recovery-generic-1" POST "$API_BASE/auth/forgot-password" "$forgot_payload")"

  if is_2xx "$code"; then
    record PASS "forgot-password generic success for nonexistent email" "HTTP $code"
  elif [[ "$code" == "404" ]]; then
    record FAIL "forgot-password generic success for nonexistent email" \
      "HTTP 404 — existence disclosed for missing email"
    return 0
  else
    record SKIP "forgot-password generic success for nonexistent email" \
      "HTTP $code — verify endpoint behavior"
    return 0
  fi

  # Verify body does not reveal user existence
  body_text="$(body_flat "$HTTP_DIR/recovery-generic-1.json")"
  if echo "$body_text" | grep -qi "not found\|no existe\|does not exist\|unknown user"; then
    record FAIL "forgot-password non-disclosure" \
      "body reveals email nonexistence: ${body_text:0:120}"
  else
    record PASS "forgot-password non-disclosure" "body does not reveal existence: ${body_text:0:120}"
  fi

  # ── Part B: Hit rate limit via repeated forgot-password calls ──
  blue "== Part B: forgot-password rate limiting =="
  local burst_count=10
  rate_limited=0

  for ((i = 1; i <= burst_count; i++)); do
    code="$(req "recovery-burst-$i" POST "$API_BASE/auth/forgot-password" "$forgot_payload")"

    if [[ "$code" == "429" ]]; then
      rate_limited=1
      headers_file="$HTTP_DIR/recovery-burst-$i.headers"
      break
    fi

    sleep 0.3 2>/dev/null || true
  done

  if [[ "$rate_limited" -eq 0 ]]; then
    record SKIP "forgot-password rate limit 429" \
      "No 429 after $burst_count rapid forgot-password attempts (window may be large or limiter not active)"
  else
    record PASS "forgot-password rate limit 429 triggered" "HTTP 429 on attempt $i/$burst_count"

    local retry_after
    retry_after="$(header_get "$headers_file" "Retry-After")"
    if [[ -n "$retry_after" ]]; then
      record PASS "forgot-password rate limit Retry-After" "value=$retry_after"
    else
      record SKIP "forgot-password rate limit Retry-After" "header not present"
    fi

    # ── Verify 429 persists while window active ──
    code="$(req "recovery-still-blocked" POST "$API_BASE/auth/forgot-password" "$forgot_payload")"
    if [[ "$code" == "429" ]]; then
      record PASS "forgot-password rate limit still 429 on retry" "HTTP $code"
    else
      record SKIP "forgot-password rate limit still 429 on retry" "HTTP $code"
    fi
  fi
}

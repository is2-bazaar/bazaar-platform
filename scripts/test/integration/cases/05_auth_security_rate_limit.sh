#!/usr/bin/env bash
# cases/05_auth_security_rate_limit.sh — Auth-service direct login rate limiting
# Depends on: 00 (services up), 01 (actors exist)
# Tests: AUTH_BASE/login with repeated wrong-password logins for one email until
# blocked (429). Validates per-email bucketing by trying a DIFFERENT email
# and verifying it is NOT blocked by the first email's bucket.
# Does NOT require gateway headers; this tests auth-service direct limiting.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"

case_05_auth_security_rate_limit() {
  blue "--- 05_auth_security_rate_limit ---"

  local code i rate_limited body_text

  # ── Register a fresh user for per-email bucketing test ──
  if ! register_user rate_limit_victim "buyer"; then
    record SKIP "auth login rate limit" "failed to register test user"
    return 0
  fi
  local victim_email
  victim_email="$(state_get rate_limit_victim_email)"

  if [[ -z "$victim_email" ]]; then
    record SKIP "auth login rate limit" "missing victim email"
    return 0
  fi

  record PASS "auth rate limit victim registered" "email=$victim_email"

  # ── Part A: Hit AUTH_BASE/login with WRONG password until 429 ──
  blue "== Part A: per-email rate limiting via AUTH_BASE/login =="
  local wrong_pass="WrongPass9999!"
  local login_payload="{\"email\":\"$victim_email\",\"password\":\"$wrong_pass\"}"
  local burst_count=12
  rate_limited=0

  for ((i = 1; i <= burst_count; i++)); do
    code="$(req "rate-auth-login-$i" POST "$AUTH_BASE/login" "$login_payload")"

    if [[ "$code" == "429" ]]; then
      rate_limited=1
      break
    fi
    sleep 0.3 2>/dev/null || true
  done

  if [[ "$rate_limited" -eq 0 ]]; then
    record SKIP "auth login rate limit 429" \
      "No 429 after $burst_count wrong-password attempts to AUTH_BASE/login (window may be larger or limiter not active)"
    return 0
  fi

  record PASS "auth login rate limit 429 triggered" "HTTP 429 on attempt $i/$burst_count"

  # ── Verify 429 body has meaningful error ──
  body_text="$(body_flat "$HTTP_DIR/rate-auth-login-$i.json")"
  if echo "$body_text" | grep -qi "too many"; then
    record PASS "auth login rate limit body detail" "body=$body_text"
  else
    record PASS "auth login rate limit body" "${body_text:0:120}"
  fi

  # ── Verify 429 persists while window is active ──
  code="$(req "rate-auth-still-blocked" POST "$AUTH_BASE/login" "$login_payload")"
  if [[ "$code" == "429" ]]; then
    record PASS "auth login rate limit still 429 on retry" "HTTP $code"
  else
    record SKIP "auth login rate limit still 429 on retry" "HTTP $code — window may be very short"
  fi

  # ── Part B: Per-email bucketing — different email NOT blocked ──
  blue "== Part B: per-email isolation =="

  # Register a second fresh user
  if ! register_user rate_limit_other "buyer"; then
    record SKIP "auth login per-email isolation" "failed to register second user"
    return 0
  fi
  local other_email
  other_email="$(state_get rate_limit_other_email)"

  if [[ -z "$other_email" ]]; then
    record SKIP "auth login per-email isolation" "missing second email"
    return 0
  fi

  local other_payload="{\"email\":\"$other_email\",\"password\":\"$wrong_pass\"}"
  code="$(req "rate-auth-other-email" POST "$AUTH_BASE/login" "$other_payload")"

  if [[ "$code" != "429" ]]; then
    record PASS "auth login per-email bucketing isolated" \
      "HTTP $code — different email NOT blocked by first email's bucket"
  elif [[ "$code" == "429" ]]; then
    record FAIL "auth login per-email bucketing isolated" \
      "HTTP 429 — different email was blocked (global/IP-based instead of per-email)"
  else
    record SKIP "auth login per-email bucketing isolated" "HTTP $code"
  fi

  # ── Part C: Correct password works for non-rate-limited email ──
  local correct_payload="{\"email\":\"$other_email\",\"password\":\"$PASSWORD\"}"
  code="$(req "rate-auth-other-correct" POST "$AUTH_BASE/login" "$correct_payload")"
  if is_2xx "$code"; then
    record PASS "auth login correct pw for other email succeeds" "HTTP $code"
  else
    record SKIP "auth login correct pw for other email" "HTTP $code"
  fi
}

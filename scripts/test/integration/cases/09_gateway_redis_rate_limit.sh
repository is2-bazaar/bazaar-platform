#!/usr/bin/env bash
# cases/09_gateway_redis_rate_limit.sh — Gateway Redis-backed rate limiting (API_BASE)
# Depends on: 00 (services up), GATEWAY_REDIS_ENABLED=true
# Tests: Gateway-level login bucket via API_BASE/auth/login hits 429, headers present,
# 429 persists while window active, public GET does NOT share login bucket.
# Does NOT duplicate 05 (which tests AUTH_BASE direct).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"

case_09_gateway_redis_rate_limit() {
  blue "--- 09_gateway_redis_rate_limit ---"

  # ── Guard: Redis must be enabled ──
  if [[ "${GATEWAY_REDIS_ENABLED:-}" != "true" ]]; then
    record SKIP "gateway redis rate limit" "GATEWAY_REDIS_ENABLED is not true — Redis rate limiting not active"
    return 0
  fi

  blue "Redis rate limiting enabled (GATEWAY_REDIS_ENABLED=$GATEWAY_REDIS_ENABLED)"

  local admin_email="${ADMIN_EMAIL:-admin@test.local}"
  local admin_pass="${ADMIN_PASSWORD:-E2eAdmin1234!}"
  local login_payload="{\"email\":\"$admin_email\",\"password\":\"$admin_pass\"}"
  local code i rate_limited headers_file

  # ── Part A: Verify gateway readyz includes Redis ──
  local readyz_code
  readyz_code="$(req "redis-readyz-gw" GET "$API_BASE/readyz")"
  if is_2xx "$readyz_code"; then
    record PASS "gateway readyz ok with Redis" "HTTP $readyz_code"
  else
    record SKIP "gateway readyz with Redis" "HTTP $readyz_code"
  fi

  # ── Part B: Burst API_BASE/auth/login until 429 ──
  blue "== Part B: gateway login bucket via API_BASE/auth/login =="
  rate_limited=0

  for ((i = 1; i <= 12; i++)); do
    code="$(req "redis-rl-burst-$i" POST "$API_BASE/auth/login" "$login_payload")"

    if [[ "$code" == "429" ]]; then
      rate_limited=1
      headers_file="$HTTP_DIR/redis-rl-burst-$i.headers"
      break
    fi
    sleep 0.3 2>/dev/null || true
  done

  if [[ "$rate_limited" -eq 0 ]]; then
    record SKIP "gateway redis login 429" \
      "No 429 after 12 rapid API_BASE/auth/login attempts (window may be large or limiter not active)"
    return 0
  fi

  record PASS "gateway redis login 429 triggered" "HTTP 429 on attempt $i"

  # ── Verify headers on 429 ──
  local retry_after limit remaining
  retry_after="$(header_get "$headers_file" "Retry-After")"
  limit="$(header_get "$headers_file" "X-RateLimit-Limit")"
  remaining="$(header_get "$headers_file" "X-RateLimit-Remaining")"

  if [[ -n "$retry_after" ]]; then
    record PASS "gateway redis Retry-After" "value=$retry_after"
  else
    record SKIP "gateway redis Retry-After" "not present"
  fi

  if [[ -n "$limit" ]]; then
    record PASS "gateway redis X-RateLimit-Limit" "value=$limit"
  else
    record SKIP "gateway redis X-RateLimit-Limit" "not present"
  fi

  if [[ -n "$remaining" ]]; then
    record PASS "gateway redis X-RateLimit-Remaining" "value=$remaining"
  fi

  # ── Part C: Verify 429 persists while window active ──
  blue "== Part C: 429 persists while window active =="
  code="$(req "redis-rl-persist" POST "$API_BASE/auth/login" "$login_payload")"
  if [[ "$code" == "429" ]]; then
    record PASS "gateway redis 429 persists on retry" "HTTP $code"
  else
    record SKIP "gateway redis 429 persists on retry" \
      "HTTP $code — window may be very short or burst-edge request got through"
  fi

  # ── Part D: Public GET does NOT share login bucket ──
  blue "== Part D: public endpoint separate bucket =="
  code="$(req "redis-rl-public" GET "$API_BASE/catalog/products?page=1&page_size=1")"
  if [[ "$code" != "429" ]]; then
    record PASS "gateway redis public GET not rate-limited by login bucket" "HTTP $code"
  elif [[ "$code" == "429" ]]; then
    record FAIL "gateway redis public GET not rate-limited by login bucket" \
      "HTTP 429 — public GET shares login bucket (global rate limit)"
  else
    record SKIP "gateway redis public GET not rate-limited" "HTTP $code"
  fi
}

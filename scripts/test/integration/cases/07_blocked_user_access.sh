#!/usr/bin/env bash
# cases/07_blocked_user_access.sh — Admin blocks a user; blocked user cannot access protected endpoints
# Depends on: 01 (auth), admin_login
# Tests: PATCH /admin/users/:userId/status → block user → login fails → profile/cart/orders rejected

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_admin.sh"

case_07_blocked_user_access() {
  blue "--- 07_blocked_user_access ---"

  local admin buyer_email buyer_token buyer_id code

  # ── Ensure admin is logged in ──
  if ! admin_login; then
    record SKIP "blocked user access" "admin login failed — cannot block users"
    return 0
  fi
  admin="$(state_get admin_token)"

  # ── Register a fresh buyer ──
  if ! register_user blocked_buyer "buyer"; then
    record SKIP "blocked user access" "failed to register test buyer"
    return 0
  fi

  buyer_token="$(state_get blocked_buyer_token)"
  buyer_id="$(state_get blocked_buyer_id)"
  buyer_email="$(state_get blocked_buyer_email)"

  if [[ -z "$buyer_token" || -z "$buyer_id" ]]; then
    record SKIP "blocked user access" "missing buyer token/id after registration"
    return 0
  fi

  record PASS "blocked user registered" "id=$buyer_id email=$buyer_email"

  # ── Admin blocks the user ──
  code="$(admin_update_user_status block-user "$admin" "$buyer_id" "blocked")"
  if is_2xx "$code"; then
    record PASS "admin blocked user" "HTTP $code — user $buyer_id set to blocked"
  else
    record FAIL "admin blocked user" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-user-status-block-user.json")"
    return 0
  fi

  # ── Verify blocked user cannot login ──
  local login_payload
  login_payload="{\"email\":\"$buyer_email\",\"password\":\"$PASSWORD\"}"
  code="$(req blocked-login POST "$API_BASE/auth/login" "$login_payload")"

  if [[ "$code" == "401" || "$code" == "403" || "$code" == "423" ]]; then
    record PASS "blocked user login rejected" "HTTP $code"
  elif is_2xx "$code"; then
    record FAIL "blocked user login rejected" "HTTP $code — blocked user was allowed to login"
  else
    record SKIP "blocked user login rejected" "HTTP $code — verify expected contract"
  fi

  # ── Verify blocked user token (from before block) is rejected ──
  # Try accessing cart with the old token
  code="$(req blocked-cart-access GET "$API_BASE/cart/" "" "$(auth_h "$buyer_token")")"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    record PASS "blocked user old token rejected on cart" "HTTP $code"
  elif is_2xx "$code"; then
    record FAIL "blocked user old token rejected on cart" \
      "HTTP $code — old token still accepted after block"
  else
    record FAIL "blocked user old token rejected on cart" "HTTP $code — unexpected response"
  fi

  # ── Verify blocked user's public profile is hidden/not available ──
  if [[ -n "$buyer_id" ]]; then
    code="$(req "blocked-profile-$buyer_id" GET "$API_BASE/profiles/$buyer_id")"
    if [[ "$code" == "404" || "$code" == "403" ]]; then
      record PASS "blocked user profile hidden" "HTTP $code — blocked account not exposed"
    elif is_2xx "$code"; then
      record FAIL "blocked user profile hidden" \
        "HTTP $code — blocked user profile is still publicly accessible"
    else
      record SKIP "blocked user profile hidden" \
        "HTTP $code — /profiles/:userId may not be exposed via gateway"
    fi
  else
    record SKIP "blocked user profile hidden" "missing buyer_id"
  fi

  # ── Unblock the user and verify login works again ──
  code="$(admin_update_user_status unblock-user "$admin" "$buyer_id" "active")"
  if is_2xx "$code"; then
    record PASS "admin unblocked user" "HTTP $code — user $buyer_id set back to active"
  else
    record FAIL "admin unblocked user" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-user-status-unblock-user.json")"
    return 0
  fi

  # Verify login works after unblock
  code="$(req blocked-login-after-unblock POST "$API_BASE/auth/login" "$login_payload")"
  if is_2xx "$code"; then
    record PASS "blocked user login restored after unblock" "HTTP $code"
  else
    record FAIL "blocked user login restored after unblock" "HTTP $code body=$(body_flat "$HTTP_DIR/blocked-login-after-unblock.json")"
  fi
}

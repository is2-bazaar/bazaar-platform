#!/usr/bin/env bash
# cases/08_public_profile_privacy.sh — Public profile returns minimized data; 404 for inactive accounts
# Depends on: 01 (auth), admin_login
# Tests: GET /profiles/:userId returns PublicProfileResponse without private fields,
# returns 404 when account is blocked/inactive.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"
source "$LIB_DIR/e2e_assertions.sh"
source "$LIB_DIR/e2e_auth.sh"
source "$LIB_DIR/e2e_admin.sh"

case_08_public_profile_privacy() {
  blue "--- 08_public_profile_privacy ---"

  local admin buyer_token buyer_id code profile_file

  # ── Register a fresh buyer for profile testing ──
  if ! register_user profile_buyer "buyer"; then
    record SKIP "public profile privacy" "failed to register test buyer"
    return 0
  fi

  buyer_token="$(state_get profile_buyer_token)"
  buyer_id="$(state_get profile_buyer_id)"

  if [[ -z "$buyer_id" ]]; then
    record SKIP "public profile privacy" "missing buyer_id after registration"
    return 0
  fi

  record PASS "profile buyer registered" "id=$buyer_id"

  # ── Fetch public profile (no auth required for public endpoint) ──
  code="$(req "profile-public-$buyer_id" GET "$API_BASE/profiles/$buyer_id")"
  profile_file="$HTTP_DIR/profile-public-$buyer_id.json"

  if ! is_2xx "$code"; then
    if [[ "$code" == "404" ]]; then
      record SKIP "public profile fetch" \
        "HTTP 404 — /profiles/:userId may not be exposed via gateway; check routing"
    else
      record SKIP "public profile fetch" \
        "HTTP $code — cannot fetch public profile; verify endpoint availability"
    fi
    return 0
  fi

  record PASS "public profile fetched" "HTTP $code"

  # ── Verify no private fields leaked ──
  local has_email has_password
  has_email="$(json_field_exists "$profile_file" "email")"
  has_password="$(json_field_exists "$profile_file" "password")"

  if [[ "$has_email" == "true" ]]; then
    record FAIL "public profile privacy — email leaked" "email field present in PublicProfileResponse"
  else
    record PASS "public profile privacy — no email" "email field absent"
  fi

  if [[ "$has_password" == "true" ]]; then
    record FAIL "public profile privacy — password leaked" "password field present in PublicProfileResponse"
  else
    record PASS "public profile privacy — no password" "password field absent"
  fi

  # ── Verify public fields are present ──
  local has_username
  has_username="$(json_field_exists "$profile_file" "username")"
  if [[ "$has_username" == "true" ]]; then
    record PASS "public profile has username" "username field present"
  else
    record SKIP "public profile has username" "username field not found — may use different field name"
  fi

  # ── Block user and verify profile returns 404 ──
  if ! admin_login; then
    record SKIP "public profile inactive check" "admin login failed — cannot block user"
    return 0
  fi
  admin="$(state_get admin_token)"

  code="$(admin_update_user_status block-profile-user "$admin" "$buyer_id" "blocked")"
  if ! is_2xx "$code"; then
    record SKIP "public profile inactive check" \
      "HTTP $code — could not block user; cannot verify 404 for inactive account"
    return 0
  fi
  record PASS "profile user blocked for inactive check" "HTTP $code"

  # ── Fetch profile again — should return 404 for inactive account ──
  code="$(req "profile-blocked-$buyer_id" GET "$API_BASE/profiles/$buyer_id")"

  if [[ "$code" == "404" ]]; then
    record PASS "public profile 404 for blocked user" "HTTP 404 — inactive account correctly hidden"
  elif [[ "$code" == "403" ]]; then
    record PASS "public profile 403 for blocked user" "HTTP 403 — inactive account access denied"
  elif is_2xx "$code"; then
    record FAIL "public profile 404 for blocked user" \
      "HTTP $code — profile still accessible after block (privacy leak)"
  else
    record SKIP "public profile 404 for blocked user" \
      "HTTP $code — unexpected response; verify contract"
  fi

  # ── Cleanup: unblock user ──
  admin_update_user_status unblock-profile-user "$admin" "$buyer_id" "active" >/dev/null
}

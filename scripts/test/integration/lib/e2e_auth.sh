#!/usr/bin/env bash
# e2e_auth.sh — Auth helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh, e2e_http.sh, e2e_json.sh

[[ -n "${_E2E_AUTH_SOURCED:-}" ]] && return 0
_E2E_AUTH_SOURCED=1

# ---------------------------------------------------------------------------
# register_user — register a new user and save state keys
# ---------------------------------------------------------------------------
register_user() {
  local label="$1"
  local role="${2:-buyer}"

  USER_SEQ=$((USER_SEQ + 1))

  local suffix="${RUN_ID: -6}${USER_SEQ}"
  local username="u${suffix}"
  local email="${username}@test.local"
  local full_name="E2E ${username}"

  local payload
  payload="$(
    cat <<JSON
{
  "email": "$email",
  "password": "$PASSWORD",
  "username": "$username"
}
JSON
  )"

  local code
  code="$(req "auth-register-$label" POST "$API_BASE/auth/register" "$payload")"

  local token user_id
  token="$(json_get "$HTTP_DIR/auth-register-$label.json" ".access_token")"

  user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".user_id")"
  [[ -z "$user_id" ]] && user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".id")"
  [[ -z "$user_id" ]] && user_id="$(json_get "$HTTP_DIR/auth-register-$label.json" ".user.id")"
  [[ -z "$user_id" && -n "$token" ]] && user_id="$(token_user_id "$token")"

  if is_2xx "$code" && [[ -n "$token" && -n "$user_id" ]]; then
    record PASS "register $label" "email=$email user_id=$user_id role=$role"
    state_put "${label}_email" "$email"
    state_put "${label}_username" "$username"
    state_put "${label}_token" "$token"
    state_put "${label}_id" "$user_id"
    return 0
  fi

  record FAIL "register $label" "HTTP $code token_present=$([[ -n "$token" ]] && echo yes || echo no) user_id=${user_id:-missing} body=$(body_flat "$HTTP_DIR/auth-register-$label.json")"
  return 1
}

# ---------------------------------------------------------------------------
# auth_suite — register all 9 actors
# ---------------------------------------------------------------------------
auth_suite() {
  blue "== Auth setup =="

  # SDD7 actors
  register_user seller_direct "seller"
  register_user buyer_direct
  register_user seller_checkout "seller"
  register_user buyer_checkout

  # SDD9 actors
  register_user seller_a "seller"
  register_user seller_b "seller"
  register_user seller_intruder "seller"
  register_user buyer_sdd9
  register_user buyer_foreign
}

# ---------------------------------------------------------------------------
# admin_login — login as admin and save admin_token state key
# ---------------------------------------------------------------------------
admin_login() {
  local payload code token cached_token

  cached_token="$(state_get admin_token)"
  if [[ -n "$cached_token" ]]; then
    code="$(req admin-login-cached-check GET "$API_BASE/admin/users/?page=1&page_size=1" "" "$(auth_h "$cached_token")")"
    if is_2xx "$code"; then
      record PASS "admin login" "email=$ADMIN_EMAIL (cached token reused)"
      return 0
    fi
  fi

  payload="$(
    cat <<JSON
{
  "email": "$ADMIN_EMAIL",
  "password": "$ADMIN_PASSWORD"
}
JSON
  )"

  code="$(req admin-login POST "$AUTH_BASE/login" "$payload")"
  token="$(json_get "$HTTP_DIR/admin-login.json" ".access_token")"

  if is_2xx "$code" && [[ -n "$token" ]]; then
    record PASS "admin login" "email=$ADMIN_EMAIL"
    state_put admin_token "$token"
    return 0
  fi

  record FAIL "admin login" "HTTP $code body=$(body_flat "$HTTP_DIR/admin-login.json")"
  return 1
}

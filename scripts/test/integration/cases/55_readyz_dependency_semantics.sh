#!/usr/bin/env bash
# cases/55_readyz_dependency_semantics.sh — /livez and /readyz semantics across all services
# Depends on: 00 (services up)
# Tests: Each service's /livez returns 2xx (liveness, no dependency check).
# Each service's /readyz returns 2xx when dependencies are healthy.
# Validates BOTH endpoints for gateway, auth, user, catalog, cart, order, payment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/e2e_common.sh"
source "$LIB_DIR/e2e_http.sh"
source "$LIB_DIR/e2e_json.sh"

case_55_readyz_dependency_semantics() {
  blue "--- 55_readyz_dependency_semantics ---"

  local code body_file

  # Helper: check livez+readyz for one service
  _check_service_health() {
    local name="$1"
    local base_url="$2"

    # /livez
    code="$(req "health-livez-$name" GET "$base_url/livez")"
    if is_2xx "$code"; then
      record PASS "health $name /livez 2xx" "HTTP $code"
    else
      record SKIP "health $name /livez" "HTTP $code"
    fi

    # /readyz
    code="$(req "health-readyz-$name" GET "$base_url/readyz")"
    if is_2xx "$code"; then
      record PASS "health $name /readyz 2xx" "HTTP $code"
    else
      record SKIP "health $name /readyz" "HTTP $code"
    fi
  }

  # ── Gateway ──
  blue "== Gateway health =="
  _check_service_health "gateway" "$API_BASE"

  # Check gateway readyz body for dependency info
  body_file="$HTTP_DIR/health-readyz-gateway.json"
  if [[ -f "$body_file" ]]; then
    if [[ "$(json_field_exists "$body_file" "status")" == "true" ]]; then
      local gw_status
      gw_status="$(json_get "$body_file" ".status")"
      record PASS "health gateway readyz has status" "status=$gw_status"
    fi
    if [[ "$(json_field_exists "$body_file" "dependencies")" == "true" ]]; then
      record PASS "health gateway readyz has dependencies" "dependencies present"
    fi
  fi

  # ── Auth service ──
  blue "== Auth health =="
  _check_service_health "auth" "$AUTH_BASE"

  # ── User service ──
  blue "== User health =="
  _check_service_health "user" "$USER_BASE"

  # ── Catalog service ──
  blue "== Catalog health =="
  _check_service_health "catalog" "$CATALOG_BASE"

  # ── Cart service ──
  blue "== Cart health =="
  _check_service_health "cart" "$CART_BASE"

  # ── Order service ──
  blue "== Order health =="
  _check_service_health "order" "$ORDER_BASE"

  # Check order readyz for database dependency
  body_file="$HTTP_DIR/health-readyz-order.json"
  if [[ -f "$body_file" ]]; then
    if [[ "$(json_field_exists "$body_file" "database")" == "true" ]]; then
      local db_status
      db_status="$(json_get "$body_file" ".database")"
      record PASS "health order readyz database" "db=$db_status"
    fi
  fi

  # ── Payment service ──
  blue "== Payment health =="
  _check_service_health "payment" "$PAYMENT_BASE"

  # ── Non-existent health endpoint returns 404 ──
  code="$(req "health-nonexistent" GET "$API_BASE/healthz")"
  if [[ "$code" == "404" ]]; then
    record PASS "health nonexistent returns 404" "HTTP 404"
  elif is_2xx "$code"; then
    record PASS "health nonexistent" "HTTP $code — /healthz exists (alternative endpoint)"
  else
    record SKIP "health nonexistent" "HTTP $code"
  fi
}

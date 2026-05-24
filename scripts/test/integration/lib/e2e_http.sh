#!/usr/bin/env bash
# e2e_http.sh — HTTP request helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh (for HTTP_DIR, CART_INTERNAL_SERVICE_TOKEN, etc.)

[[ -n "${_E2E_HTTP_SOURCED:-}" ]] && return 0
_E2E_HTTP_SOURCED=1

# ---------------------------------------------------------------------------
# HTTP request — dumps body, headers, code, and masked request log
# ---------------------------------------------------------------------------
req() {
  local label="$1"
  local method="$2"
  local url="$3"
  local payload="${4:-}"
  shift 4 || true

  local headers="$HTTP_DIR/$label.headers"
  local body="$HTTP_DIR/$label.json"
  local code_file="$HTTP_DIR/$label.code"
  local req_file="$HTTP_DIR/$label.request.txt"

  {
    echo "$method $url"
    local h
    for h in "$@"; do
      case "$h" in
        Authorization:*) echo "Authorization: Bearer ***" ;;
        X-Internal-Service-Token:*) echo "X-Internal-Service-Token: ***" ;;
        *) echo "$h" ;;
      esac
    done
    [[ -n "$payload" ]] && echo "BODY: $(mask_password_in_payload "$payload")"
  } >"$req_file"

  local args=(curl -sS -X "$method" "$url" -D "$headers" -o "$body" -w '%{http_code}' -H "Accept: application/json")

  if [[ -n "$payload" ]]; then
    args+=(-H "Content-Type: application/json" --data "$payload")
  fi

  local h
  for h in "$@"; do
    [[ -n "$h" ]] && args+=(-H "$h")
  done

  local code
  code="$("${args[@]}" 2>/dev/null || printf "000")"
  printf '%s' "$code" >"$code_file"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# header_get — extract a single response header value from a headers file
# Usage: header_get <headers_file> <header_name>
# Example: header_get "$HTTP_DIR/label.headers" "Retry-After"
# Uses AWK: case-insensitive match, trims leading spaces after colon,
# strips trailing CR, prints first match and exits.
# ---------------------------------------------------------------------------
header_get() {
  local file="$1"
  local name="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }
  awk -v hdr="$name" 'BEGIN{IGNORECASE=1} $0~"^"hdr":"{sub(/^[^:]+:[[:space:]]*/,""); sub(/\r$/,""); print; exit}' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Status code predicates
# ---------------------------------------------------------------------------
is_2xx() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }
is_4xx() { [[ "$1" =~ ^4[0-9][0-9]$ ]]; }
is_401_403() { [[ "$1" == "401" || "$1" == "403" ]]; }

# ---------------------------------------------------------------------------
# Header builders
# ---------------------------------------------------------------------------
auth_h() { printf "Authorization: Bearer %s" "$1"; }
internal_h() { printf "X-Internal-Service-Token: %s" "$INTERNAL_SERVICE_TOKEN"; }
cart_internal_h() { printf "X-Internal-Service-Token: %s" "$CART_INTERNAL_SERVICE_TOKEN"; }

# ---------------------------------------------------------------------------
# Body helpers
# ---------------------------------------------------------------------------
body_flat() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tr '\n' ' ' <"$file" | sed 's/[[:space:]]\+/ /g' | sed 's/|/\//g'
}

mask_password_in_payload() {
  local payload="$1"
  printf '%s\n' "$payload" | sed 's/"password":"[^"]*"/"password":"***"/g'
}

# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------
wait_ready_one() {
  local label="$1"
  local url="$2"
  local max="${3:-60}"
  local i code body

  for ((i = 1; i <= max; i++)); do
    code="$(req "wait-$label-$i" GET "$url/readyz")"

    if is_2xx "$code"; then
      record PASS "ready $label" "HTTP $code after attempt $i/$max"
      return 0
    fi

    body="$(body_flat "$HTTP_DIR/wait-$label-$i.json")"
    yellow "WAIT - ready $label - attempt $i/$max HTTP $code ${body:0:160}"
    sleep 5
  done

  record FAIL "ready $label" "last HTTP $code body=$(body_flat "$HTTP_DIR/wait-$label-$max.json")"
  return 1
}

wake_services() {
  blue "== Wake services / readiness =="

  wait_ready_one auth "$AUTH_BASE"
  wait_ready_one user "$USER_BASE"
  wait_ready_one catalog "$CATALOG_BASE"
  wait_ready_one cart "$CART_BASE"
  wait_ready_one order "$ORDER_BASE"
  wait_ready_one payment "$PAYMENT_BASE"
  wait_ready_one gateway "$API_BASE"

  req "warmup-gateway-livez" GET "$API_BASE/livez" >/dev/null
  req "warmup-catalog-products" GET "$API_BASE/catalog/products?page=1&page_size=1" >/dev/null
  req "warmup-cart-auth-check" GET "$API_BASE/cart/" >/dev/null
  req "warmup-cart-readyz" GET "$CART_BASE/readyz" >/dev/null
  req "warmup-payment-readyz" GET "$PAYMENT_BASE/readyz" >/dev/null

  sleep 2
}

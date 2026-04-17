#!/usr/bin/env bash

platform_backend_allowed_origins() {
  local origins=""

  origins="$(platform_append_allowed_origin_for_url "$origins" "$BACKOFFICE_DEV_URL")"
  origins="$(platform_append_allowed_origin_for_url "$origins" "$MOBILE_DEV_URL")"

  printf '%s\n' "$origins"
}

platform_backend_select_stack() {
  case "${BACKEND_STACK:-full}" in
    full)
      PLATFORM_GATEWAY_ENABLED_SERVICES="auth,user,catalog,inventory,cart,orders,payments,notifications"
      # shellcheck disable=SC2034
      PLATFORM_COMPOSE_SERVICES=(
        api-gateway
        auth-service
        user-service
        catalog-service
        inventory-service
        cart-service
        orders-service
        payments-service
        notifications-service
      )
      ;;
    auth)
      PLATFORM_GATEWAY_ENABLED_SERVICES="auth,user"
      # shellcheck disable=SC2034
      PLATFORM_COMPOSE_SERVICES=(
        api-gateway
        auth-service
        user-service
      )
      ;;
    *)
      platform_fail "BACKEND_STACK invalido: ${BACKEND_STACK:-}. Valores soportados: full, auth"
      ;;
  esac
}

platform_env_value_for_key() {
  local file_path="$1"
  local key="$2"
  local raw

  [[ -f "$file_path" ]] || return 1

  raw="$(grep -E "^[[:space:]]*${key}=" "$file_path" | tail -n 1 || true)"
  [[ -n "$raw" ]] || return 1

  raw="${raw#*=}"
  raw="${raw%$'\r'}"
  raw="${raw#\"}"
  raw="${raw%\"}"
  raw="${raw#\'}"
  raw="${raw%\'}"

  printf '%s\n' "$raw"
}

platform_resolve_jwt_secret() {
  local resolved="${JWT_SECRET:-}"
  local from_file

  if [[ -n "${resolved//[[:space:]]/}" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  for candidate in "$BAZAAR_AUTH_SERVICE_PATH/.env" "$BAZAAR_AUTH_SERVICE_PATH/.env.local"; do
    from_file="$(platform_env_value_for_key "$candidate" "JWT_SECRET" || true)"
    if [[ -n "${from_file//[[:space:]]/}" ]]; then
      resolved="$from_file"
    fi
  done

  printf '%s\n' "$resolved"
}

platform_compose() {
  local allowed_origins
  local resolved_jwt_secret
  allowed_origins="$(platform_backend_allowed_origins)"
  resolved_jwt_secret="$(platform_resolve_jwt_secret)"

  if [[ -z "${resolved_jwt_secret//[[:space:]]/}" ]]; then
    platform_warn "JWT_SECRET no definido en entorno ni en $BAZAAR_AUTH_SERVICE_PATH/.env(.local); se usara fallback de desarrollo"
  fi

  BAZAAR_BACKEND_PATH="$BAZAAR_BACKEND_PATH" \
    BAZAAR_API_GATEWAY_PATH="$BAZAAR_API_GATEWAY_PATH" \
    BAZAAR_AUTH_SERVICE_PATH="$BAZAAR_AUTH_SERVICE_PATH" \
    BAZAAR_CATALOG_SERVICE_PATH="$BAZAAR_CATALOG_SERVICE_PATH" \
    BAZAAR_USER_SERVICE_PATH="$BAZAAR_USER_SERVICE_PATH" \
    JWT_SECRET="$resolved_jwt_secret" \
    GATEWAY_ALLOWED_ORIGINS="$allowed_origins" \
    GATEWAY_ENABLED_SERVICES="$PLATFORM_GATEWAY_ENABLED_SERVICES" \
    docker compose -f "$PLATFORM_COMPOSE_FILE" "$@"
}

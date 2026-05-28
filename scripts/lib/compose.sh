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
      PLATFORM_GATEWAY_ENABLED_SERVICES="auth,user,catalog,cart,orders,payments,recommendations"
      # shellcheck disable=SC2034
      PLATFORM_COMPOSE_SERVICES=(
        api-gateway
        auth-service
        user-service
        rabbitmq
        recommendation-db
        catalog-service
        cart-service
        orders-service
        payment-service
        recommendation-service
        recommendation-worker
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

platform_resolve_internal_service_token() {
  local resolved="${INTERNAL_SERVICE_TOKEN:-}"
  local from_file

  if [[ -n "${resolved//[[:space:]]/}" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  for candidate in "$BAZAAR_AUTH_SERVICE_PATH/.env" "$BAZAAR_AUTH_SERVICE_PATH/.env.local"; do
    from_file="$(platform_env_value_for_key "$candidate" "INTERNAL_SERVICE_TOKEN" || true)"
    if [[ -n "${from_file//[[:space:]]/}" ]]; then
      resolved="$from_file"
    fi
  done

  printf '%s\n' "$resolved"
}

platform_export_if_set() {
  local variable_name

  for variable_name in "$@"; do
    if [[ ${!variable_name+x} == x ]]; then
      export "${variable_name?}"
    fi
  done
}

platform_compose() {
  local allowed_origins
  local resolved_internal_service_token
  local resolved_jwt_secret
  allowed_origins="$(platform_backend_allowed_origins)"
  resolved_internal_service_token="$(platform_resolve_internal_service_token)"
  resolved_jwt_secret="$(platform_resolve_jwt_secret)"

  if [[ -z "${resolved_jwt_secret//[[:space:]]/}" ]]; then
    platform_warn "JWT_SECRET no definido en entorno ni en $BAZAAR_AUTH_SERVICE_PATH/.env(.local); se usara fallback de desarrollo"
  fi

  if [[ -z "${resolved_internal_service_token//[[:space:]]/}" ]]; then
    platform_warn "INTERNAL_SERVICE_TOKEN no definido en entorno ni en $BAZAAR_AUTH_SERVICE_PATH/.env(.local); los endpoints internos pueden fallar"
  fi

  export INTERNAL_SERVICE_TOKEN="$resolved_internal_service_token"
  export BAZAAR_API_GATEWAY_PATH="$BAZAAR_API_GATEWAY_PATH"
  export BAZAAR_AUTH_SERVICE_PATH="$BAZAAR_AUTH_SERVICE_PATH"
  export BAZAAR_CART_SERVICE_PATH="$BAZAAR_CART_SERVICE_PATH"
  export BAZAAR_CATALOG_SERVICE_PATH="$BAZAAR_CATALOG_SERVICE_PATH"
  export BAZAAR_ORDER_SERVICE_PATH="$BAZAAR_ORDER_SERVICE_PATH"
  export BAZAAR_PAYMENT_SERVICE_PATH="$BAZAAR_PAYMENT_SERVICE_PATH"
  export BAZAAR_RECOMMENDATION_SERVICE_PATH="$BAZAAR_RECOMMENDATION_SERVICE_PATH"
  export BAZAAR_USER_SERVICE_PATH="$BAZAAR_USER_SERVICE_PATH"
  export CART_DB_NAME="${CART_DB_NAME:-cart_db}"
  export JWT_SECRET="$resolved_jwt_secret"
  export GATEWAY_ALLOWED_ORIGINS="$allowed_origins"
  export GATEWAY_ENABLED_SERVICES="$PLATFORM_GATEWAY_ENABLED_SERVICES"

  platform_export_if_set \
    PAYMENT_PROVIDER \
    PAYMENT_SIMULATION_MODE \
    MERCADOPAGO_ACCESS_TOKEN \
    PAYMENT_WEBHOOK_URL \
    MERCADOPAGO_WEBHOOK_SECRET \
    MERCADOPAGO_WEBHOOK_MAX_SKEW_SECONDS \
    ORDER_SERVICE_URL \
    PAYMENT_SERVICE_URL \
    PAYMENTS_SERVICE_URL \
    CHECKOUT_SUCCESS_URL \
    CHECKOUT_FAILURE_URL \
    CHECKOUT_PENDING_URL \
    ALLOW_EXPO_RETURN_URLS \
    PAYMENT_EXPIRATION_MINUTES

  docker compose -f "$PLATFORM_COMPOSE_FILE" "$@"
}

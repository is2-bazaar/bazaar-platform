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
      PLATFORM_GATEWAY_ENABLED_SERVICES="auth"
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

platform_compose() {
  local allowed_origins
  allowed_origins="$(platform_backend_allowed_origins)"

  BAZAAR_BACKEND_PATH="$BAZAAR_BACKEND_PATH" \
    BAZAAR_API_GATEWAY_PATH="$BAZAAR_API_GATEWAY_PATH" \
    BAZAAR_AUTH_SERVICE_PATH="$BAZAAR_AUTH_SERVICE_PATH" \
    GATEWAY_ALLOWED_ORIGINS="$allowed_origins" \
    GATEWAY_ENABLED_SERVICES="$PLATFORM_GATEWAY_ENABLED_SERVICES" \
    docker compose -f "$PLATFORM_COMPOSE_FILE" "$@"
}

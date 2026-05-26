#!/usr/bin/env bash

platform_root() {
  (cd "$PLATFORM_COMMON_DIR/.." && pwd)
}

resolve_from_root() {
  local root="$1"
  local path="$2"
  local candidate

  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)
      candidate="$root/$path"

      if [[ -d "$candidate" ]]; then
        (cd "$candidate" && pwd)
      elif [[ -f "$candidate" ]]; then
        (
          cd "$(dirname "$candidate")" &&
            printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")"
        )
      else
        printf '%s\n' "$candidate"
      fi
      ;;
  esac
}

platform_snapshot_env_vars() {
  local variable_name

  for variable_name in "$@"; do
    unset "PLATFORM_ENV_SNAPSHOT_$variable_name"

    if [[ ${!variable_name+x} == x ]]; then
      printf -v "PLATFORM_ENV_SNAPSHOT_$variable_name" '%s' "${!variable_name}"
    else
      printf -v "PLATFORM_ENV_SNAPSHOT_$variable_name" '%s' "__PLATFORM_UNSET__"
    fi
  done
}

platform_restore_env_overrides() {
  local variable_name
  local snapshot_var
  local snapshot_value

  for variable_name in "$@"; do
    snapshot_var="PLATFORM_ENV_SNAPSHOT_$variable_name"
    snapshot_value="${!snapshot_var-__PLATFORM_UNSET__}"

    if [[ "$snapshot_value" != "__PLATFORM_UNSET__" ]]; then
      printf -v "$variable_name" '%s' "$snapshot_value"
    fi
  done
}

platform_require_repo_script() {
  local repo_label="$1"
  local repo_root="$2"
  local script_name="$3"
  local script_path="$repo_root/scripts/dev/$script_name"

  [[ -n "$repo_root" ]] || platform_fail "$repo_label no esta configurado"
  [[ -d "$repo_root" ]] || platform_fail "no se encontro $repo_label en $repo_root"
  [[ -f "$script_path" ]] || platform_fail "no se encontro el entrypoint de $repo_label: $script_path"
}

platform_rewrite_url_host_if_matches() {
  local variable_name="$1"
  local old_host="$2"
  local new_host="$3"
  local url_value="${!variable_name-}"

  [[ -n "$old_host" && -n "$new_host" && -n "$url_value" ]] || return 0

  if [[ "$(platform_url_host "$url_value")" == "$old_host" ]]; then
    printf -v "$variable_name" '%s' "$(platform_url_with_host "$url_value" "$new_host")"
  fi
}

load_platform_env() {
  local snapshot_vars=(
    ENV_NAME
    BAZAAR_API_GATEWAY_PATH
    BAZAAR_AUTH_SERVICE_PATH
    BAZAAR_CART_SERVICE_PATH
    BAZAAR_CATALOG_SERVICE_PATH
    BAZAAR_ORDER_SERVICE_PATH
    BAZAAR_PAYMENT_SERVICE_PATH
    BAZAAR_RECOMMENDATION_SERVICE_PATH
    BAZAAR_USER_SERVICE_PATH
    BAZAAR_BACKOFFICE_PATH
    BAZAAR_MOBILE_PATH
    BACKEND_PROVIDER
    DATABASE_PROVIDER
    BACKOFFICE_PROVIDER
    MOBILE_RUNTIME_MODE
    LOCAL_API_BASE_URL
    BACKOFFICE_DEV_URL
    MOBILE_API_BASE_URL
    MOBILE_DEV_URL
    PLATFORM_LAN_IP
    BACKEND_STACK
    CART_DB_NAME
    INTERNAL_SERVICE_TOKEN
  )
  local path_var
  local url_var
  local defaults_file
  local configured_platform_lan_ip

  PLATFORM_ROOT="$(platform_root)"
  defaults_file="$PLATFORM_ROOT/defaults.env"

  [[ -f "$defaults_file" ]] || platform_fail "falta defaults.env en $PLATFORM_ROOT"

  platform_snapshot_env_vars "${snapshot_vars[@]}"

  # shellcheck disable=SC1090,SC1091
  source "$defaults_file"

  if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "$PLATFORM_ROOT/.env.local"
  fi

  platform_restore_env_overrides "${snapshot_vars[@]}"

  for path_var in BAZAAR_API_GATEWAY_PATH BAZAAR_AUTH_SERVICE_PATH BAZAAR_CART_SERVICE_PATH BAZAAR_CATALOG_SERVICE_PATH BAZAAR_ORDER_SERVICE_PATH BAZAAR_PAYMENT_SERVICE_PATH BAZAAR_RECOMMENDATION_SERVICE_PATH BAZAAR_USER_SERVICE_PATH BAZAAR_BACKOFFICE_PATH BAZAAR_MOBILE_PATH; do
    printf -v "$path_var" '%s' "$(resolve_from_root "$PLATFORM_ROOT" "${!path_var-}")"
  done

  # shellcheck disable=SC2034
  PLATFORM_COMPOSE_FILE="$PLATFORM_ROOT/infra/compose/docker-compose.platform.yml"

  for url_var in LOCAL_API_BASE_URL BACKOFFICE_DEV_URL MOBILE_API_BASE_URL MOBILE_DEV_URL; do
    local url_value="${!url_var-}"
    printf -v "$url_var" '%s' "${url_value%/}"
  done

  require_env BAZAAR_API_GATEWAY_PATH
  require_env BAZAAR_AUTH_SERVICE_PATH
  require_env BAZAAR_CART_SERVICE_PATH
  require_env BAZAAR_CATALOG_SERVICE_PATH
  require_env BAZAAR_ORDER_SERVICE_PATH
  require_env BAZAAR_PAYMENT_SERVICE_PATH
  require_env BAZAAR_RECOMMENDATION_SERVICE_PATH
  require_env BAZAAR_USER_SERVICE_PATH
  require_env BAZAAR_BACKOFFICE_PATH
  require_env BAZAAR_MOBILE_PATH
  require_env LOCAL_API_BASE_URL
  require_env BACKOFFICE_DEV_URL
  require_env MOBILE_API_BASE_URL
  require_env MOBILE_DEV_URL

  configured_platform_lan_ip="${PLATFORM_LAN_IP:-}"
  PLATFORM_LAN_IP="$(platform_resolve_lan_ip "$configured_platform_lan_ip")"

  if [[ -n "$configured_platform_lan_ip" && "$configured_platform_lan_ip" != "$PLATFORM_LAN_IP" ]]; then
    platform_rewrite_url_host_if_matches MOBILE_API_BASE_URL "$configured_platform_lan_ip" "$PLATFORM_LAN_IP"
    platform_rewrite_url_host_if_matches MOBILE_DEV_URL "$configured_platform_lan_ip" "$PLATFORM_LAN_IP"
  fi
}

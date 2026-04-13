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

load_platform_env() {
  local snapshot_vars=(
    ENV_NAME
    BAZAAR_BACKEND_PATH
    BAZAAR_API_GATEWAY_PATH
    BAZAAR_AUTH_SERVICE_PATH
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
  )
  local path_var
  local url_var
  local defaults_file

  PLATFORM_ROOT="$(platform_root)"
  defaults_file="$PLATFORM_ROOT/defaults.env"

  [[ -f "$defaults_file" ]] || platform_fail "falta defaults.env en $PLATFORM_ROOT"

  platform_snapshot_env_vars "${snapshot_vars[@]}"

  # shellcheck disable=SC1091
  source "$defaults_file"

  if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "$PLATFORM_ROOT/.env.local"
  fi

  platform_restore_env_overrides "${snapshot_vars[@]}"

  for path_var in BAZAAR_BACKEND_PATH BAZAAR_API_GATEWAY_PATH BAZAAR_AUTH_SERVICE_PATH BAZAAR_USER_SERVICE_PATH BAZAAR_BACKOFFICE_PATH BAZAAR_MOBILE_PATH; do
    printf -v "$path_var" '%s' "$(resolve_from_root "$PLATFORM_ROOT" "${!path_var-}")"
  done

  PLATFORM_COMPOSE_FILE="$PLATFORM_ROOT/infra/compose/docker-compose.platform.yml"

  for url_var in LOCAL_API_BASE_URL BACKOFFICE_DEV_URL MOBILE_API_BASE_URL MOBILE_DEV_URL; do
    local url_value="${!url_var-}"
    printf -v "$url_var" '%s' "${url_value%/}"
  done

  require_env BAZAAR_BACKEND_PATH
  require_env BAZAAR_API_GATEWAY_PATH
  require_env BAZAAR_AUTH_SERVICE_PATH
  require_env BAZAAR_USER_SERVICE_PATH
  require_env BAZAAR_BACKOFFICE_PATH
  require_env BAZAAR_MOBILE_PATH
  require_env LOCAL_API_BASE_URL
  require_env BACKOFFICE_DEV_URL
  require_env MOBILE_API_BASE_URL
  require_env MOBILE_DEV_URL

  PLATFORM_LAN_IP="${PLATFORM_LAN_IP:-$(platform_detect_lan_ip)}"
}

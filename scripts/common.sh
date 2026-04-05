#!/usr/bin/env bash

platform_info() {
  printf '[platform] %s\n' "$*"
}

platform_ok() {
  printf '[platform][ok] %s\n' "$*"
}

platform_warn() {
  printf '[platform][warn] %s\n' "$*"
}

platform_fail() {
  printf '[platform][error] %s\n' "$*" >&2
  exit 1
}

platform_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$script_dir/.." && pwd)
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

load_platform_env() {
  PLATFORM_ROOT="$(platform_root)"
  local defaults_file
  local existing_env_name="${ENV_NAME:-}"
  local existing_backend_path="${BAZAAR_BACKEND_PATH:-}"
  local existing_backoffice_path="${BAZAAR_BACKOFFICE_PATH:-}"
  local existing_mobile_path="${BAZAAR_MOBILE_PATH:-}"
  local existing_backend_provider="${BACKEND_PROVIDER:-}"
  local existing_database_provider="${DATABASE_PROVIDER:-}"
  local existing_backoffice_provider="${BACKOFFICE_PROVIDER:-}"
  local existing_mobile_runtime_mode="${MOBILE_RUNTIME_MODE:-}"
  local existing_local_api_base_url="${LOCAL_API_BASE_URL:-}"
  local existing_backoffice_dev_url="${BACKOFFICE_DEV_URL:-}"
  local existing_mobile_api_base_url="${MOBILE_API_BASE_URL:-}"
  local existing_mobile_dev_url="${MOBILE_DEV_URL:-}"
  local existing_platform_lan_ip="${PLATFORM_LAN_IP:-}"
  local existing_backend_stack="${BACKEND_STACK:-}"

  defaults_file="$PLATFORM_ROOT/defaults.env"
  [[ -f "$defaults_file" ]] || platform_fail "falta defaults.env en $PLATFORM_ROOT"

  # shellcheck disable=SC1091
  source "$defaults_file"

  if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "$PLATFORM_ROOT/.env.local"
  fi

  [[ -n "$existing_env_name" ]] && ENV_NAME="$existing_env_name"
  [[ -n "$existing_backend_path" ]] && BAZAAR_BACKEND_PATH="$existing_backend_path"
  [[ -n "$existing_backoffice_path" ]] && BAZAAR_BACKOFFICE_PATH="$existing_backoffice_path"
  [[ -n "$existing_mobile_path" ]] && BAZAAR_MOBILE_PATH="$existing_mobile_path"
  [[ -n "$existing_backend_provider" ]] && BACKEND_PROVIDER="$existing_backend_provider"
  [[ -n "$existing_database_provider" ]] && DATABASE_PROVIDER="$existing_database_provider"
  [[ -n "$existing_backoffice_provider" ]] && BACKOFFICE_PROVIDER="$existing_backoffice_provider"
  [[ -n "$existing_mobile_runtime_mode" ]] && MOBILE_RUNTIME_MODE="$existing_mobile_runtime_mode"
  [[ -n "$existing_local_api_base_url" ]] && LOCAL_API_BASE_URL="$existing_local_api_base_url"
  [[ -n "$existing_backoffice_dev_url" ]] && BACKOFFICE_DEV_URL="$existing_backoffice_dev_url"
  [[ -n "$existing_mobile_api_base_url" ]] && MOBILE_API_BASE_URL="$existing_mobile_api_base_url"
  [[ -n "$existing_mobile_dev_url" ]] && MOBILE_DEV_URL="$existing_mobile_dev_url"
  [[ -n "$existing_platform_lan_ip" ]] && PLATFORM_LAN_IP="$existing_platform_lan_ip"
  [[ -n "$existing_backend_stack" ]] && BACKEND_STACK="$existing_backend_stack"

  BAZAAR_BACKEND_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_BACKEND_PATH}")"
  BAZAAR_BACKOFFICE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_BACKOFFICE_PATH}")"
  BAZAAR_MOBILE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_MOBILE_PATH}")"
  LOCAL_API_BASE_URL="${LOCAL_API_BASE_URL%/}"
  BACKOFFICE_DEV_URL="${BACKOFFICE_DEV_URL%/}"
  MOBILE_API_BASE_URL="${MOBILE_API_BASE_URL%/}"
  MOBILE_DEV_URL="${MOBILE_DEV_URL%/}"

  require_env BAZAAR_BACKEND_PATH
  require_env BAZAAR_BACKOFFICE_PATH
  require_env BAZAAR_MOBILE_PATH
  require_env LOCAL_API_BASE_URL
  require_env BACKOFFICE_DEV_URL
  require_env MOBILE_DEV_URL

  PLATFORM_LAN_IP="${PLATFORM_LAN_IP:-$(platform_detect_lan_ip)}"
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    platform_fail "falta el comando requerido: $command_name"
  fi
}

require_env() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    platform_fail "falta la variable requerida: $variable_name"
  fi
}

platform_detect_lan_ip() {
  local lan_ip=""

  if command -v ip >/dev/null 2>&1; then
    lan_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi

  if [[ -z "$lan_ip" ]] && command -v hostname >/dev/null 2>&1; then
    lan_ip="$(hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i !~ /^172\\.(1[6-9]|2[0-9]|3[0-1])\\./) {print $i; exit}}')"
  fi

  printf '%s\n' "$lan_ip"
}

platform_mobile_device_api_url() {
  if [[ -z "${PLATFORM_LAN_IP:-}" ]]; then
    return 1
  fi

  local api_origin="${MOBILE_API_BASE_URL#*://}"
  local api_suffix=""
  local api_scheme="http"

  if [[ "$MOBILE_API_BASE_URL" == *"://"* ]]; then
    api_scheme="${MOBILE_API_BASE_URL%%://*}"
  fi

  if [[ "$api_origin" == */* ]]; then
    api_suffix="/${api_origin#*/}"
    api_origin="${api_origin%%/*}"
  fi

  if [[ "$api_origin" == *:* ]]; then
    printf '%s://%s:%s%s\n' "$api_scheme" "$PLATFORM_LAN_IP" "${api_origin##*:}" "$api_suffix"
    return 0
  fi

  printf '%s://%s%s\n' "$api_scheme" "$PLATFORM_LAN_IP" "$api_suffix"
}

platform_mobile_device_url() {
  if [[ -z "${PLATFORM_LAN_IP:-}" ]]; then
    return 1
  fi

  local mobile_origin="${MOBILE_DEV_URL#*://}"
  local mobile_scheme="http"

  if [[ "$MOBILE_DEV_URL" == *"://"* ]]; then
    mobile_scheme="${MOBILE_DEV_URL%%://*}"
  fi

  printf '%s://%s:%s\n' "$mobile_scheme" "$PLATFORM_LAN_IP" "${mobile_origin##*:}"
}

platform_run_backend_script() {
  local script_name="$1"

  BACKEND_LOCAL_API_BASE_URL="$LOCAL_API_BASE_URL" \
    BACKEND_STACK="${BACKEND_STACK:-full}" \
    bash "$BAZAAR_BACKEND_PATH/scripts/dev/$script_name"
}

platform_run_backoffice_script() {
  local script_name="$1"

  BACKOFFICE_API_BASE_URL="$LOCAL_API_BASE_URL" \
    BACKOFFICE_DEV_URL="$BACKOFFICE_DEV_URL" \
    bash "$BAZAAR_BACKOFFICE_PATH/scripts/dev/$script_name"
}

platform_run_mobile_script() {
  local script_name="$1"

  MOBILE_API_BASE_URL="$MOBILE_API_BASE_URL" \
    MOBILE_DEV_URL="$MOBILE_DEV_URL" \
    bash "$BAZAAR_MOBILE_PATH/scripts/dev/$script_name"
}

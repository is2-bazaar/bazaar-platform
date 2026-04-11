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
  local existing_api_gateway_path="${BAZAAR_API_GATEWAY_PATH:-}"
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
  [[ -n "$existing_api_gateway_path" ]] && BAZAAR_API_GATEWAY_PATH="$existing_api_gateway_path"
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
  BAZAAR_API_GATEWAY_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_API_GATEWAY_PATH}")"
  BAZAAR_BACKOFFICE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_BACKOFFICE_PATH}")"
  BAZAAR_MOBILE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_MOBILE_PATH}")"
  PLATFORM_COMPOSE_FILE="$PLATFORM_ROOT/infra/compose/docker-compose.platform.yml"
  LOCAL_API_BASE_URL="${LOCAL_API_BASE_URL%/}"
  BACKOFFICE_DEV_URL="${BACKOFFICE_DEV_URL%/}"
  MOBILE_API_BASE_URL="${MOBILE_API_BASE_URL%/}"
  MOBILE_DEV_URL="${MOBILE_DEV_URL%/}"

  require_env BAZAAR_BACKEND_PATH
  require_env BAZAAR_API_GATEWAY_PATH
  require_env BAZAAR_BACKOFFICE_PATH
  require_env BAZAAR_MOBILE_PATH
  require_env LOCAL_API_BASE_URL
  require_env BACKOFFICE_DEV_URL
  require_env MOBILE_API_BASE_URL
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

platform_require_repo_script() {
  local repo_label="$1"
  local repo_root="$2"
  local script_name="$3"
  local script_path="$repo_root/scripts/dev/$script_name"

  [[ -n "$repo_root" ]] || platform_fail "$repo_label no esta configurado"
  [[ -d "$repo_root" ]] || platform_fail "no se encontro $repo_label en $repo_root"
  [[ -f "$script_path" ]] || platform_fail "no se encontro el entrypoint de $repo_label: $script_path"
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

platform_url_scheme() {
  local url="$1"

  if [[ "$url" == *"://"* ]]; then
    printf '%s\n' "${url%%://*}"
    return 0
  fi

  printf 'http\n'
}

platform_url_origin() {
  local url="$1"
  local origin="${url#*://}"

  printf '%s\n' "${origin%%/*}"
}

platform_url_path() {
  local url="$1"
  local origin="${url#*://}"

  if [[ "$origin" == */* ]]; then
    printf '/%s\n' "${origin#*/}"
    return 0
  fi

  printf '\n'
}

platform_url_host() {
  local origin
  origin="$(platform_url_origin "$1")"

  if [[ "$origin" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$origin" == *:* ]]; then
    printf '%s\n' "${origin%%:*}"
    return 0
  fi

  printf '%s\n' "$origin"
}

platform_url_port() {
  local origin
  origin="$(platform_url_origin "$1")"

  if [[ "$origin" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$origin" =~ ^\[[^]]+\]$ ]]; then
    printf '\n'
    return 0
  fi

  if [[ "$origin" == *:* ]]; then
    printf '%s\n' "${origin##*:}"
    return 0
  fi

  printf '\n'
}

platform_host_is_loopback() {
  case "$1" in
    localhost|127.0.0.1|0.0.0.0|::1|"[::1]"|::|"[::]")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

platform_url_origin_value() {
  local url="$1"

  printf '%s://%s\n' "$(platform_url_scheme "$url")" "$(platform_url_origin "$url")"
}

platform_format_url_host() {
  local host="$1"

  if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
    printf '[%s]\n' "$host"
    return 0
  fi

  printf '%s\n' "$host"
}

platform_origin_with_host() {
  local url="$1"
  local host="$2"
  local port
  local formatted_host

  formatted_host="$(platform_format_url_host "$host")"

  port="$(platform_url_port "$url")"
  if [[ -n "$port" ]]; then
    printf '%s://%s:%s\n' "$(platform_url_scheme "$url")" "$formatted_host" "$port"
    return 0
  fi

  printf '%s://%s\n' "$(platform_url_scheme "$url")" "$formatted_host"
}

platform_append_csv_unique() {
  local csv="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    printf '%s\n' "$csv"
    return 0
  fi

  if [[ -n "$csv" ]] && printf '%s\n' ",$csv," | grep -F -q -- ",$value,"; then
    printf '%s\n' "$csv"
    return 0
  fi

  if [[ -z "$csv" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  printf '%s,%s\n' "$csv" "$value"
}

platform_append_allowed_origin_for_url() {
  local csv="$1"
  local url="$2"
  local origin
  local host

  origin="$(platform_url_origin_value "$url")"
  csv="$(platform_append_csv_unique "$csv" "$origin")"

  host="$(platform_url_host "$url")"
  if [[ -n "${PLATFORM_LAN_IP:-}" ]] && platform_host_is_loopback "$host"; then
    csv="$(platform_append_csv_unique "$csv" "$(platform_origin_with_host "$url" "$PLATFORM_LAN_IP")")"
  fi

  printf '%s\n' "$csv"
}

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
    GATEWAY_ALLOWED_ORIGINS="$allowed_origins" \
    GATEWAY_ENABLED_SERVICES="$PLATFORM_GATEWAY_ENABLED_SERVICES" \
    docker compose -f "$PLATFORM_COMPOSE_FILE" "$@"
}

platform_http_probe() {
  local url="$1"

  curl --connect-timeout 2 --max-time 5 -fsS "$url" >/dev/null 2>&1
}

platform_wait_for_ready() {
  local url="$1"
  local timeout_seconds="${2:-90}"
  local deadline

  deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if platform_http_probe "$url"; then
      return 0
    fi

    sleep 2
  done

  return 1
}

platform_mobile_effective_api_base_url() {
  local api_base_url="$MOBILE_API_BASE_URL"
  local api_host
  local api_port
  local api_scheme
  local api_path

  if [[ -z "${PLATFORM_LAN_IP:-}" ]]; then
    printf '%s\n' "$api_base_url"
    return 0
  fi

  api_host="$(platform_url_host "$api_base_url")"
  if ! platform_host_is_loopback "$api_host"; then
    printf '%s\n' "$api_base_url"
    return 0
  fi

  api_scheme="$(platform_url_scheme "$api_base_url")"
  api_port="$(platform_url_port "$api_base_url")"
  api_path="$(platform_url_path "$api_base_url")"

  if [[ -n "$api_port" ]]; then
    printf '%s://%s:%s%s\n' "$api_scheme" "$(platform_format_url_host "$PLATFORM_LAN_IP")" "$api_port" "$api_path"
    return 0
  fi

  printf '%s://%s%s\n' "$api_scheme" "$(platform_format_url_host "$PLATFORM_LAN_IP")" "$api_path"
}

platform_mobile_device_api_url() {
  platform_mobile_effective_api_base_url
}

platform_mobile_device_probe_url() {
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

platform_mobile_device_url() {
  local probe_url
  local expo_scheme="exp"

  probe_url="$(platform_mobile_device_probe_url)" || return 1

  if [[ "$probe_url" == https://* ]]; then
    expo_scheme="exps"
  fi

  printf '%s://%s\n' "$expo_scheme" "${probe_url#*://}"
}

platform_run_backoffice_script() {
  local script_name="$1"

  BACKOFFICE_API_BASE_URL="$LOCAL_API_BASE_URL" \
    BACKOFFICE_DEV_URL="$BACKOFFICE_DEV_URL" \
    bash "$BAZAAR_BACKOFFICE_PATH/scripts/dev/$script_name"
}

platform_run_mobile_script() {
  local script_name="$1"
  local mobile_dev_url="$MOBILE_DEV_URL"

  if [[ -n "${PLATFORM_LAN_IP:-}" ]]; then
    mobile_dev_url="$(platform_mobile_device_probe_url)"
  fi

  MOBILE_API_BASE_URL="$(platform_mobile_effective_api_base_url)" \
    MOBILE_DEV_URL="$mobile_dev_url" \
    bash "$BAZAAR_MOBILE_PATH/scripts/dev/$script_name"
}

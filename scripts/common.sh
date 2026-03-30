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

  defaults_file="$PLATFORM_ROOT/defaults.env"
  [[ -f "$defaults_file" ]] || platform_fail "falta defaults.env en $PLATFORM_ROOT"

  # shellcheck disable=SC1091
  source "$defaults_file"

  if [[ -f "$PLATFORM_ROOT/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "$PLATFORM_ROOT/.env.local"
  fi

  BAZAAR_BACKEND_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_BACKEND_PATH}")"
  BAZAAR_BACKOFFICE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_BACKOFFICE_PATH}")"
  BAZAAR_MOBILE_PATH="$(resolve_from_root "$PLATFORM_ROOT" "${BAZAAR_MOBILE_PATH}")"
  LOCAL_API_BASE_URL="${LOCAL_API_BASE_URL%/}"
  BACKOFFICE_DEV_URL="${BACKOFFICE_DEV_URL%/}"
  MOBILE_API_BASE_URL="${MOBILE_API_BASE_URL%/}"

  require_env BAZAAR_BACKEND_PATH
  require_env BAZAAR_BACKOFFICE_PATH
  require_env BAZAAR_MOBILE_PATH
  require_env LOCAL_API_BASE_URL
  require_env BACKOFFICE_DEV_URL
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

http_probe() {
  local url="$1"

  curl --connect-timeout 2 --max-time 5 -fsS "$url" >/dev/null 2>&1
}

wait_for_ready() {
  local url="$1"
  local timeout_seconds="${2:-60}"
  local deadline

  deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if http_probe "$url"; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      break
    fi

    sleep 2
  done

  return 1
}

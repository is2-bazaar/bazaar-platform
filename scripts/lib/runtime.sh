#!/usr/bin/env bash

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

platform_mobile_effective_dev_url() {
  if [[ -n "${PLATFORM_LAN_IP:-}" ]]; then
    platform_mobile_device_probe_url
    return 0
  fi

  printf '%s\n' "$MOBILE_DEV_URL"
}

platform_mobile_device_api_url() {
  platform_mobile_effective_api_base_url
}

platform_mobile_device_probe_url() {
  if [[ -z "${PLATFORM_LAN_IP:-}" ]]; then
    return 1
  fi

  local mobile_host
  local mobile_port
  local mobile_scheme="http"

  if [[ "$MOBILE_DEV_URL" == *"://"* ]]; then
    mobile_scheme="${MOBILE_DEV_URL%%://*}"
  fi

  mobile_host="$(platform_url_host "$MOBILE_DEV_URL")"
  mobile_port="$(platform_url_port "$MOBILE_DEV_URL")"

  if [[ -n "$mobile_port" ]]; then
    printf '%s://%s:%s\n' "$mobile_scheme" "$PLATFORM_LAN_IP" "$mobile_port"
    return 0
  fi

  if [[ -z "$mobile_host" ]]; then
    printf '%s://%s\n' "$mobile_scheme" "$PLATFORM_LAN_IP"
    return 0
  fi

  printf '%s://%s\n' "$mobile_scheme" "$PLATFORM_LAN_IP"
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

  MOBILE_API_BASE_URL="$(platform_mobile_effective_api_base_url)" \
    MOBILE_DEV_URL="$(platform_mobile_effective_dev_url)" \
    bash "$BAZAAR_MOBILE_PATH/scripts/dev/$script_name"
}

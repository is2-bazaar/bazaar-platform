#!/usr/bin/env bash

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
    localhost | 127.0.0.1 | 0.0.0.0 | ::1 | "[::1]" | :: | "[::]")
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

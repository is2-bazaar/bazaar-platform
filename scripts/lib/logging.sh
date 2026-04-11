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

#!/usr/bin/env bash

set -euo pipefail

readonly COMPOSE_FILE="compose/docker-compose.release.yml"
readonly ENV_FILE=".env.staging"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    fail "missing required file: $path"
  fi
}

require_var() {
  local name="$1"

  if [[ -z "${!name:-}" ]]; then
    fail "missing required variable: $name"
  fi
}

require_file "$ENV_FILE"
require_file "$COMPOSE_FILE"

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

require_var "API_GATEWAY_IMAGE"
require_var "IDENTITY_SERVICE_IMAGE"
require_var "DB_URL"
require_var "JWT_SECRET"
require_var "CORS_ALLOWED_ORIGINS"

skip_pull="${SKIP_DOCKER_PULL:-false}"

if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  printf '%s\n' "Logging in to ghcr.io as ${GHCR_USERNAME}"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null
else
  printf '%s\n' "Skipping ghcr.io login because GHCR_USERNAME/GHCR_TOKEN are not both defined"
fi

if [[ "$skip_pull" == "true" ]]; then
  printf '%s\n' "Skipping docker compose pull because SKIP_DOCKER_PULL=true"
else
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps

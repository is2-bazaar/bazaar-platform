#!/usr/bin/env bash

set -euo pipefail

readonly COMPOSE_FILE="compose/docker-compose.local.yml"
readonly ENV_FILE=".env.local"
readonly API_PORT="${API_GATEWAY_PORT:-8080}"

compose_cmd() {
  if [[ -f "$ENV_FILE" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

wait_for_http() {
  local url="$1"
  local name="$2"

  for _ in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  printf 'error: %s did not become reachable: %s\n' "$name" "$url" >&2
  exit 1
}

compose_cmd ps
wait_for_http "http://127.0.0.1:${API_PORT}/livez" "api-gateway"
wait_for_http "http://127.0.0.1:${API_PORT}/identity/livez" "identity-service"

if ! grep -Eq '^VITE_API_BASE_URL=http://localhost:8080$' ../bazaar-backoffice/.env.example; then
  printf '%s\n' 'error: ../bazaar-backoffice/.env.example is not pointing to http://localhost:8080' >&2
  exit 1
fi

printf '%s\n' 'Smoke checks passed'

#!/usr/bin/env bash

set -euo pipefail

readonly COMPOSE_FILE="compose/docker-compose.local.yml"
readonly ENV_FILE=".env.local"

if [[ -f "$ENV_FILE" ]]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up --build -d
else
  docker compose -f "$COMPOSE_FILE" up --build -d
fi

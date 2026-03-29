.PHONY: validate up-local down-local smoke-local backoffice-check backoffice-dev compose-config

validate:
	@tmp_env="$$(mktemp)"; \
	trap 'rm -f "$$tmp_env"' EXIT; \
	printf '%s\n' \
		"API_GATEWAY_PORT=8080" \
		"IDENTITY_SERVICE_PORT=8080" \
		"POSTGRES_DB=identity" \
		"POSTGRES_USER=postgres" \
		"POSTGRES_PASSWORD=postgres" \
		"POSTGRES_PORT=5433" \
		"VITE_API_BASE_URL=http://localhost:8080" \
	> "$$tmp_env"; \
	docker compose --env-file "$$tmp_env" -f compose/docker-compose.local.yml config >/dev/null; \
	for key in \
		API_GATEWAY_PORT \
		IDENTITY_SERVICE_PORT \
		POSTGRES_DB \
		POSTGRES_USER \
		POSTGRES_PASSWORD \
		POSTGRES_PORT \
		VITE_API_BASE_URL; do \
		grep -Eq "^$$key=" .env.local.example || { \
			printf 'Missing required key in .env.local.example: %s\n' "$$key" >&2; \
			exit 1; \
		}; \
	done; \
	npm --prefix ../bazaar-backoffice run typecheck >/dev/null; \
	npm --prefix ../bazaar-backoffice run build >/dev/null

compose-config:
	@docker compose --env-file .env.local.example -f compose/docker-compose.local.yml config

up-local:
	@bash scripts/local/up-local.sh

down-local:
	@bash scripts/local/down-local.sh

smoke-local:
	@bash scripts/local/smoke-local.sh

backoffice-check:
	@npm --prefix ../bazaar-backoffice run typecheck
	@npm --prefix ../bazaar-backoffice run build

backoffice-dev:
	@VITE_API_BASE_URL=http://localhost:8080 npm --prefix ../bazaar-backoffice run dev

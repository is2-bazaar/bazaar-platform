.PHONY: validate compose-config deploy-staging-local

validate:
	@tmp_env="$$(mktemp)"; \
	trap 'rm -f "$$tmp_env"' EXIT; \
	printf '%s\n' \
		"API_GATEWAY_IMAGE=ghcr.io/example/bazaar-api-gateway:sha-dummy" \
		"IDENTITY_SERVICE_IMAGE=ghcr.io/example/bazaar-identity-service:sha-dummy" \
		"API_GATEWAY_PORT=8080" \
		"IDENTITY_SERVICE_PORT=8080" \
		"DB_URL='postgresql://user:password@host/db?sslmode=require'" \
		"JWT_SECRET='dummy-jwt-secret'" \
		"CORS_ALLOWED_ORIGINS='https://staging.example.com'" \
	> "$$tmp_env"; \
	docker compose --env-file "$$tmp_env" -f compose/docker-compose.release.yml config >/dev/null; \
	for key in \
		STAGING_HOST \
		STAGING_USER \
		STAGING_DB_URL \
		STAGING_JWT_SECRET \
		STAGING_CORS_ALLOWED_ORIGINS \
		GHCR_USERNAME \
		GHCR_TOKEN \
		API_GATEWAY_IMAGE \
		IDENTITY_SERVICE_IMAGE; do \
		grep -Eq "^$$key=" .env.staging.example || { \
			printf 'Missing required key in .env.staging.example: %s\n' "$$key" >&2; \
			exit 1; \
		}; \
	done

compose-config:
	@docker compose --env-file .env.staging.example -f compose/docker-compose.release.yml config

deploy-staging-local:
	@test -f .env.staging || { \
		printf '%s\n' "Missing .env.staging in the current directory" >&2; \
		exit 1; \
	}
	@bash scripts/deploy/deploy-staging.sh

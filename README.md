# bazaar-platform

Repositorio minimo de composicion y deploy para Bazaar.

## Alcance de esta v1

- Solo resuelve `staging`.
- No hace builds de imagenes.
- No hace PRs automaticos cross-repo.
- No despliega `production`.
- No contiene logica de negocio ni contratos OpenAPI.

`bazaar-platform` asume que `bazaar-backend` ya publica imagenes versionadas a GHCR u otro registry compatible.

## Contrato operativo

- El host remoto de `staging` ya debe existir.
- El host remoto debe tener Docker y Docker Compose plugin instalados.
- El usuario remoto debe poder ejecutar Docker.
- El deploy remoto usa SSH.
- Los secretos viven en GitHub Environment `STAGING`.
- El directorio remoto estandar es `/opt/bazaar-platform/staging`.
- El archivo remoto de variables es `/opt/bazaar-platform/staging/.env.staging`.

## Stack minimo

Esta v1 despliega solamente:

- `api-gateway`
- `identity-service`

Las imagenes se inyectan por variables:

- `API_GATEWAY_IMAGE`
- `IDENTITY_SERVICE_IMAGE`

## Variables

`.env.staging.example` documenta dos grupos de variables:

- variables de GitHub Environment para el workflow (`STAGING_*`)
- variables runtime que terminan en `.env.staging`

En esta v1, `DB_URL` queda reservado para `identity-service`. El `api-gateway` no lo consume.

Ese archivo existe solo como documentacion. No debe usarse como archivo real de secretos.

Para pruebas locales sin GHCR, podes usar tags locales como `bazaar-api-gateway:local` y `bazaar-identity-service:local` junto con `SKIP_DOCKER_PULL=true`.

## Healthchecks

El compose release usa `/livez` como contrato minimo de healthcheck.

Esto es intencional: en esta v1 el `api-gateway` solo se despliega junto a `identity-service`, por lo que `/readyz` del gateway podria fallar si el resto de los servicios todavia no forma parte del stack release.

## Comandos

```bash
make validate
make compose-config
make deploy-staging-local
```

## GitHub Environment `STAGING`

Definir al menos estos valores:

- Variables:
  - `STAGING_HOST`
  - `STAGING_USER`
- Secrets:
  - `STAGING_SSH_PRIVATE_KEY`
  - `STAGING_SSH_KNOWN_HOSTS`
  - `STAGING_DB_URL`
  - `STAGING_JWT_SECRET`
  - `STAGING_CORS_ALLOWED_ORIGINS`
  - `GHCR_USERNAME`
  - `GHCR_TOKEN`
  - `API_GATEWAY_IMAGE`
  - `IDENTITY_SERVICE_IMAGE`
  - opcionalmente `API_GATEWAY_PORT`
  - opcionalmente `IDENTITY_SERVICE_PORT`

## Flujo manual de deploy

1. Completar los valores del Environment `STAGING` en GitHub.
2. Ejecutar `make validate` localmente.
3. Lanzar `.github/workflows/deploy-staging.yml` por `workflow_dispatch`.
4. El workflow copia los archivos minimos, genera `.env.staging` en el host remoto y ejecuta el script de deploy.

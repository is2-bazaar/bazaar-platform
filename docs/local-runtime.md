# Contrato de runtime local

## Rol de `bazaar-platform`

`bazaar-platform` existe para orquestar y documentar el entorno integrado local. No es un repo de deploy, no define cloud y no absorbe responsabilidad de negocio de los otros repos.

La vista general de ambientes y providers vive en [environments.md](./environments.md). Este documento se enfoca solo en el runtime local.

## Unidad local: backend integrado

En esta etapa, `platform` es el owner del compose local del backend. El compose integra:

- `Bazaar-backend-api-gateway` como source of truth del gateway
- `bazaar-backend-auth-service` como source of truth de `auth-service`
- `bazaar-backend-user-service` como source of truth de `user-service`
- `bazaar-backend` como source of truth de los microservicios que siguen en el monorepo

Contrato operativo esperado:

- repos disponibles en disco
- compose local estable en `infra/compose/docker-compose.platform.yml`
- gateway accesible en `LOCAL_API_BASE_URL`
- allowlist CORS del gateway calculada por `platform`

## Inputs esperados

- repo `Bazaar-backend-api-gateway` disponible en `BAZAAR_API_GATEWAY_PATH`
- repo `bazaar-backend-auth-service` disponible en `BAZAAR_AUTH_SERVICE_PATH` (debe incluir `.env` o `.env.local` para configuracion interna del servicio)
- repo `bazaar-backend-user-service` disponible en `BAZAAR_USER_SERVICE_PATH` (debe incluir `.env` o `.env.local` para configuracion interna del servicio)
- repo `bazaar-backend` disponible en `BAZAAR_BACKEND_PATH`
- `LOCAL_API_BASE_URL`
- `BACKEND_STACK`
- `GATEWAY_ALLOWED_ORIGINS` derivada por `platform`

Nota: `JWT_SECRET` se resuelve desde `bazaar-backend-auth-service/.env(.local)` (o desde la variable de entorno del host) y se inyecta por `platform` a `auth-service` y `user-service` para validar access tokens, sin compartir el `.env` completo de auth con otros servicios. `user-service` tambien puede usar su propio `.env` en modo standalone, pero en el compose integrado la fuente de verdad del secreto sigue siendo auth.

## Outputs esperados

- `scripts/up.sh`: deja el compose backend arriba, garantiza readiness del gateway y devuelve exit code 0
- `scripts/down.sh`: apaga el compose backend y devuelve exit code 0
- `scripts/status.sh`: imprime estado del compose y reachability basica del gateway

## Significado de `ready`

Para `platform`, el backend integrado esta `ready` cuando el gateway responde exitosamente en:

- `GET $LOCAL_API_BASE_URL/readyz`

`platform` usa esa señal como readiness del backend completo para desarrollo local. No inspecciona flujos de negocio ni clouds futuros.

## CORS local

`platform` deriva `GATEWAY_ALLOWED_ORIGINS` desde:

- `BACKOFFICE_DEV_URL`
- `MOBILE_DEV_URL`
- `PLATFORM_LAN_IP` cuando hace falta exponer origins equivalentes para dispositivo fisico o acceso por LAN

Ni `bazaar-backend` ni `Bazaar-backend-api-gateway` deben hardcodear origins locales en codigo para el flujo integrado.

## Stacks soportados

`BACKEND_STACK` define que parte del backend integrado se levanta:

- `full`: gateway + todos los servicios actuales
- `auth`: gateway + auth-service + user-service + dependencias minimas

El gateway publica solo las rutas consistentes con el stack seleccionado para que `/readyz` represente lo que realmente esta levantado.

## Que puede cambiar sin romper a `platform`

- nombres internos de microservicios
- topologia interna de builds en cada repo
- detalles de bases de datos internas
- deploy cloud o providers futuros

## Que no puede cambiar sin actualizar `platform`

- ubicacion del repo del gateway o del repo backend sin reflejarlo en defaults/envs
- existencia del compose local integrado
- existencia del gateway en `LOCAL_API_BASE_URL`
- semantica operativa de `/readyz`
- provision de `GATEWAY_ALLOWED_ORIGINS` durante el runtime local

## Unidad local: backoffice

El backoffice se ejecuta fuera de Docker:

- mediante `scripts/dev/up.sh`
- `BACKOFFICE_API_BASE_URL` apuntando al gateway local
- `status.sh` y `down.sh` encapsulando PID, logs y readiness

`platform` no conoce Vite ni `npm run dev`; solo invoca el contrato del repo.

## Unidad local: mobile

`mobile` tambien queda tratado como caja negra:

- se levanta mediante `scripts/dev/up.sh`
- recibe `MOBILE_API_BASE_URL`
- expone `status.sh` y `down.sh`
- consume la misma API local, con las consideraciones normales de Expo y dispositivo fisico
- `platform` puede informar la IP LAN detectada y las URLs a usar desde un dispositivo fisico

## Variables del contrato local

### En `platform`

- `ENV_NAME`
- `BAZAAR_BACKEND_PATH`
- `BAZAAR_API_GATEWAY_PATH`
- `BAZAAR_AUTH_SERVICE_PATH`
- `BAZAAR_USER_SERVICE_PATH`
- `BAZAAR_BACKOFFICE_PATH`
- `BAZAAR_MOBILE_PATH`
- `BACKEND_PROVIDER`
- `DATABASE_PROVIDER`
- `BACKOFFICE_PROVIDER`
- `MOBILE_RUNTIME_MODE`
- `BACKEND_STACK`
- `LOCAL_API_BASE_URL`
- `BACKOFFICE_DEV_URL`
- `MOBILE_API_BASE_URL`
- `MOBILE_DEV_URL`
  Valor base HTTP del bundler de Expo. `platform` deriva desde ahi la URL `exp://...` para Expo Go cuando detecta una IP LAN.
- `PLATFORM_LAN_IP`

### Defaults efectivos

- `ENV_NAME=local`
- `BAZAAR_BACKEND_PATH=../bazaar-backend`
- `BAZAAR_API_GATEWAY_PATH=../Bazaar-backend-api-gateway`
- `BAZAAR_AUTH_SERVICE_PATH=../bazaar-backend-auth-service`
- `BAZAAR_USER_SERVICE_PATH=../bazaar-backend-user-service`
- `BAZAAR_BACKOFFICE_PATH=../bazaar-backoffice`
- `BAZAAR_MOBILE_PATH=../bazaar-mobile`
- `BACKEND_PROVIDER=local-docker`
- `DATABASE_PROVIDER=local-docker`
- `BACKOFFICE_PROVIDER=local-vite`
- `MOBILE_RUNTIME_MODE=local-expo`
- `BACKEND_STACK=full`
- `LOCAL_API_BASE_URL=http://localhost:8080`
- `BACKOFFICE_DEV_URL=http://localhost:5173`
- `MOBILE_API_BASE_URL=http://localhost:8080`
- `MOBILE_DEV_URL=http://localhost:8081`

## Decisiones explicitamente postergadas

- deploy cloud por repo
- observabilidad real cross-repo
- contratos ejecutables de staging o production
- smoke tests de negocio end-to-end

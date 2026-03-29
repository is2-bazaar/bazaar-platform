# bazaar-platform

Repositorio de orquestacion local para Bazaar.

## Alcance de esta v1

- Orquesta localmente `api-gateway`, `identity-service` y `postgres`.
- Integra el `bazaar-backoffice` como consumidor local del backend.
- No orquesta la app mobile.
- No hace deploy remoto.
- No usa GHCR, SSH ni staging en esta etapa.

Esta v1 esta pensada para ser coherente con un futuro stack `Render + Vercel + Neon`:

- `postgres` local emula el rol futuro de Neon.
- los servicios backend en Docker emulan el rol futuro de Render.
- el backoffice fuera de Docker emula el rol futuro de Vercel.

## Que corre y que no corre

Corre desde `bazaar-platform`:

- `api-gateway`
- `identity-service`
- `postgres`
- chequeos del `bazaar-backoffice`

No corre automaticamente:

- `bazaar-mobile`

La app mobile queda documentada como consumidor separado del backend.

## Workspace esperado

Este repo asume que existen repos hermanos en:

- `../bazaar-backend`
- `../bazaar-backoffice`
- `../bazaar-mobile`

## Variables

`.env.local.example` documenta las variables minimas para correr el slice local.

En esta v1:

- `api-gateway` usa `PORT` e `IDENTITY_SERVICE_URL`
- `identity-service` usa `PORT` y `DEPENDENCY_TARGETS`
- `postgres` se configura por variables locales de compose
- `bazaar-backoffice` usa `VITE_API_BASE_URL=http://localhost:8080`

`.env.local` es opcional y local. No se commitea.

## Healthchecks

El compose local usa `/livez` como contrato minimo de healthcheck para backend.

## Comandos

```bash
make validate
make up-local
make down-local
make smoke-local
make backoffice-check
make backoffice-dev
```

## Flujo local recomendado

1. Ejecutar `make validate`.
2. Levantar backend y Postgres con `make up-local`.
3. Verificar salud con `make smoke-local`.
4. Validar el backoffice con `make backoffice-check`.
5. Correr el backoffice con `make backoffice-dev`.

## Relacion con el TP

Esta v1 es coherente como primer paso porque refuerza:

- entorno local reproducible
- integracion entre componentes
- separacion de responsabilidades entre repos

No reemplaza la necesidad posterior de deploy cloud automatizado.

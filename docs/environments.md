# Contrato de ambientes

## Rol de `bazaar-platform`

`bazaar-platform` documenta el contrato de ambientes de Bazaar y solo orquesta el entorno local. En esta etapa no despliega, no provisiona cloud y no gestiona secretos.

## Matriz de ambientes

| Ambiente | Backend | Base de datos | Backoffice | Mobile | Orquestado por `platform` | API consumida |
| --- | --- | --- | --- | --- | --- | --- |
| Local | Stack local del backend | Local, dentro del stack backend | Dev server local con Vite | Manual, fuera de automatizacion | Si, solo backend y launcher del backoffice | `LOCAL_API_BASE_URL` |
| Staging | Render | Neon | Vercel | Manual, flujo separado | No | `BACKEND_BASE_URL` de staging |
| Production | Render | Neon | Vercel | Manual, release separado | No | `BACKEND_BASE_URL` de production |

## Consumo de API por cliente

### Backoffice

- Local: consume `LOCAL_API_BASE_URL`.
- Staging: debe consumir `BACKEND_BASE_URL` del contrato de staging.
- Production: debe consumir `BACKEND_BASE_URL` del contrato de production.

### Mobile

- Local: consume `MOBILE_API_BASE_URL`, pero puede requerir override hacia la IP del host o alias del emulador.
- Staging: consume la URL publica del backend staging.
- Production: consume la URL publica del backend production.

## Providers previstos

- Backend: `local-docker` en local, `render` en staging y production.
- Base de datos: `local-docker` en local, `neon` en staging y production.
- Backoffice: `local-vite` en local, `vercel` en staging y production.
- Mobile: manual en todos los ambientes desde la perspectiva de `platform`.

## Variables que si pertenecen a `platform`

- `ENV_NAME`
- `BAZAAR_BACKEND_PATH`
- `BAZAAR_BACKOFFICE_PATH`
- `BAZAAR_MOBILE_PATH`
- `BACKEND_PROVIDER`
- `DATABASE_PROVIDER`
- `BACKOFFICE_PROVIDER`
- `MOBILE_RUNTIME_MODE`
- `LOCAL_API_BASE_URL`
- `BACKOFFICE_DEV_URL`
- `MOBILE_API_BASE_URL`
- `BACKEND_BASE_URL` en contratos documentales
- `BACKOFFICE_BASE_URL` en contratos documentales

## Variables que no pertenecen a `platform`

- `DATABASE_URL`
- credenciales de providers
- secretos de JWT, pagos, mail o sesiones
- variables internas entre microservicios
- nombres de containers o servicios internos
- flags de runtime propios del backend

## Decisiones explicitamente postergadas

- deploy real a Render, Neon y Vercel
- nombres reales de recursos cloud
- sincronizacion de variables hacia providers
- CI/CD entre ambientes
- promocion de staging a production
- automatizacion de `mobile`

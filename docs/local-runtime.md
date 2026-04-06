# Contrato de runtime local

## Rol de `bazaar-platform`

`bazaar-platform` existe para orquestar y documentar el entorno integrado local. No es un repo de deploy, no define cloud y no absorbe responsabilidad de los otros repos.

La vista general de ambientes y providers vive en [environments.md](./environments.md). Este documento se enfoca solo en el runtime local.

## Unidad local: backend

En esta etapa, `platform` trata a `bazaar-backend` como una sola unidad operativa:

- lo arranca mediante su entrypoint local de repo
- no necesita conocer nombres de microservicios
- consume solo la interfaz `scripts/dev/*`

Contrato operativo esperado:

- repo disponible en disco
- scripts de desarrollo estables
- gateway accesible en `LOCAL_API_BASE_URL`
- allowlist CORS del gateway calculada por `platform`

## Interfaz estable de backend para `platform`

### Inputs esperados

- repo `bazaar-backend` disponible en `BAZAAR_BACKEND_PATH`
- scripts ejecutables:
  - `scripts/dev/up.sh`
  - `scripts/dev/down.sh`
  - `scripts/dev/status.sh`
- gateway accesible en `LOCAL_API_BASE_URL`
- `GATEWAY_ALLOWED_ORIGINS` provista por `platform` al invocar los entrypoints del backend

### Outputs esperados

- `up.sh`: deja el backend arriba, garantiza readiness del gateway y devuelve exit code 0
- `down.sh`: apaga el backend y devuelve exit code 0
- `status.sh`: imprime estado del compose y checks basicos del gateway

### Significado de `ready`

Para `platform`, el contrato del backend considera al sistema `ready` cuando el gateway responde exitosamente en:

- `GET $LOCAL_API_BASE_URL/readyz`

`platform` no implementa ese readiness por su cuenta: delega el arranque a `scripts/dev/up.sh` y asume que el repo backend solo devuelve exit code 0 una vez que esa condicion ya esta cumplida. Tampoco inspecciona microservicios individuales ni nombres internos del backend.

### CORS local

`platform` deriva `GATEWAY_ALLOWED_ORIGINS` desde:

- `BACKOFFICE_DEV_URL`
- `MOBILE_DEV_URL`
- `PLATFORM_LAN_IP` cuando hace falta exponer origins equivalentes para dispositivo fisico o acceso por LAN

El backend no debe hardcodear origins locales en codigo, compose ni scripts de desarrollo. Si se ejecuta standalone fuera de `platform`, cualquier necesidad de CORS queda bajo responsabilidad explicita del runtime que lo lanza.

### Que puede cambiar sin romper a `platform`

- nombres de microservicios internos
- topologia interna del compose
- detalles de bases de datos internas

### Que no puede cambiar sin actualizar `platform`

- ubicacion o existencia de `scripts/dev/up.sh`, `down.sh`, `status.sh`
- existencia del gateway en `LOCAL_API_BASE_URL`
- semantica operativa de `/readyz` como señal de backend listo
- provision de `GATEWAY_ALLOWED_ORIGINS` durante el runtime integrado local

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
- `BAZAAR_BACKOFFICE_PATH`
- `BAZAAR_MOBILE_PATH`
- `BACKEND_PROVIDER`
- `DATABASE_PROVIDER`
- `BACKOFFICE_PROVIDER`
- `MOBILE_RUNTIME_MODE`
- `LOCAL_API_BASE_URL`
- `BACKOFFICE_DEV_URL`
- `MOBILE_API_BASE_URL`
- `MOBILE_DEV_URL`
- `PLATFORM_LAN_IP` opcional para override manual de la IP LAN mostrada al usuario

### Defaults efectivos

- `ENV_NAME=local`
- `BAZAAR_BACKEND_PATH=../bazaar-backend`
- `BAZAAR_BACKOFFICE_PATH=../bazaar-backoffice`
- `BAZAAR_MOBILE_PATH=../bazaar-mobile`
- `BACKEND_PROVIDER=local-docker`
- `DATABASE_PROVIDER=local-docker`
- `BACKOFFICE_PROVIDER=local-vite`
- `MOBILE_RUNTIME_MODE=local-expo`
- `LOCAL_API_BASE_URL=http://localhost:8080`
- `BACKOFFICE_DEV_URL=http://localhost:5173`
- `MOBILE_API_BASE_URL=http://localhost:8080`
- `MOBILE_DEV_URL=http://localhost:8081`

### En backend

- variables de runtime y servicio
- credenciales locales de base de datos
- URLs entre servicios
- configuracion propia del compose o de los binarios

### En backoffice

- `BACKOFFICE_API_BASE_URL`
- `BACKOFFICE_DEV_URL`
- futuras variables propias del frontend

### En mobile

- `MOBILE_API_BASE_URL`
- `MOBILE_DEV_URL`
- futuras variables propias del runtime Expo

## Decisiones explicitamente postergadas

- compose integrador propio en `platform`
- cloud y deploy remoto
- observabilidad real cross-repo
- contratos ejecutables de staging o production
- smoke tests de negocio end-to-end

# Contrato de runtime local

## Rol de `bazaar-platform`

`bazaar-platform` existe para orquestar y documentar el entorno integrado local. No es un repo de deploy, no define cloud y no absorbe responsabilidad de los otros repos.

La vista general de ambientes y providers vive en [environments.md](./environments.md). Este documento se enfoca solo en el runtime local.

## Unidad local: backend

En esta etapa, `platform` trata a `bazaar-backend` como una sola unidad operativa:

- lo arranca mediante su entrypoint local de repo
- espera a que el gateway quede `ready`
- no necesita conocer nombres de microservicios

Contrato operativo esperado:

- repo disponible en disco
- scripts de desarrollo estables
- gateway accesible en `LOCAL_API_BASE_URL`

## Interfaz estable de backend para `platform`

### Inputs esperados

- repo `bazaar-backend` disponible en `BAZAAR_BACKEND_PATH`
- scripts ejecutables:
  - `scripts/dev/up.sh`
  - `scripts/dev/down.sh`
  - `scripts/dev/status.sh`
- gateway accesible en `LOCAL_API_BASE_URL`

### Outputs esperados

- `up.sh`: deja el backend arriba y devuelve exit code 0
- `down.sh`: apaga el backend y devuelve exit code 0
- `status.sh`: imprime estado del compose y checks basicos del gateway

### Significado de `ready`

Para `platform`, el backend esta `ready` cuando el gateway responde exitosamente en:

- `GET $LOCAL_API_BASE_URL/readyz`

`platform` no inspecciona microservicios individuales ni nombres internos del backend.

### Que puede cambiar sin romper a `platform`

- nombres de microservicios internos
- topologia interna del compose
- detalles de bases de datos internas

### Que no puede cambiar sin actualizar `platform`

- ubicacion o existencia de `scripts/dev/up.sh`, `down.sh`, `status.sh`
- existencia del gateway en `LOCAL_API_BASE_URL`
- semantica operativa de `/readyz` como señal de backend listo

## Unidad local: backoffice

El backoffice se ejecuta fuera de Docker:

- `npm run dev`
- `VITE_API_BASE_URL` apuntando al gateway local

`platform` puede validar o inyectar defaults de entorno, pero no se vuelve dueño de la configuracion del frontend.

## Unidad local: mobile

`mobile` queda fuera de la automatizacion de `platform`:

- no se levanta desde `platform`
- se documenta su path local
- consume la misma API local, con las consideraciones normales de Expo y dispositivo fisico

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

### Defaults efectivos

- `ENV_NAME=local`
- `BAZAAR_BACKEND_PATH=../bazaar-backend`
- `BAZAAR_BACKOFFICE_PATH=../bazaar-backoffice`
- `BAZAAR_MOBILE_PATH=../bazaar-mobile`
- `BACKEND_PROVIDER=local-docker`
- `DATABASE_PROVIDER=local-docker`
- `BACKOFFICE_PROVIDER=local-vite`
- `MOBILE_RUNTIME_MODE=manual`
- `LOCAL_API_BASE_URL=http://localhost:8080`
- `BACKOFFICE_DEV_URL=http://localhost:5173`
- `MOBILE_API_BASE_URL=http://localhost:8080`

### En backend

- variables de runtime y servicio
- credenciales locales de base de datos
- URLs entre servicios
- configuracion propia del compose o de los binarios

### En backoffice

- `VITE_API_BASE_URL`
- futuras `VITE_*` propias del frontend

## Decisiones explicitamente postergadas

- compose integrador propio en `platform`
- cloud y deploy remoto
- observabilidad real cross-repo
- contratos ejecutables de staging o production
- automatizacion de `mobile`
- smoke tests de negocio end-to-end

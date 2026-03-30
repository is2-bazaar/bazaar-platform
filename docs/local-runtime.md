# Contrato de runtime local

## Rol de `bazaar-platform`

`bazaar-platform` existe para orquestar y documentar el entorno integrado local. No es un repo de deploy, no define cloud y no absorbe responsabilidad de los otros repos.

## Unidad local: backend

En esta etapa, `platform` trata a `bazaar-backend` como una sola unidad operativa:

- lo arranca mediante su entrypoint local de repo
- espera a que el gateway quede `ready`
- no necesita conocer nombres de microservicios

Contrato operativo esperado:

- repo disponible en disco
- scripts de desarrollo estables
- gateway accesible en `LOCAL_API_BASE_URL`

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

- `BAZAAR_BACKEND_PATH`
- `BAZAAR_BACKOFFICE_PATH`
- `BAZAAR_MOBILE_PATH`
- `LOCAL_API_BASE_URL`
- `BACKOFFICE_DEV_URL`

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
- automatizacion de `mobile`
- smoke tests de negocio end-to-end

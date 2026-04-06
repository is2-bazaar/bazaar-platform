# bazaar-platform

Thin wrapper para correr Bazaar en desarrollo local sin duplicar infraestructura ajena.

## Objetivo

`bazaar-platform` coordina:

- el backend como una unidad local runnable
- el backoffice como dev server local
- el mobile como runtime local de Expo
- la documentacion del contrato de entorno

No resuelve cloud y no contiene logica de negocio.

## Estructura

```text
.
├── defaults.env
├── .env.local.example
├── .env.staging.example
├── .env.production.example
├── docs/
│   ├── environments.md
│   └── local-runtime.md
└── scripts/
    ├── common.sh
    ├── check.sh
    ├── up.sh
    ├── backoffice.sh
    ├── mobile.sh
    ├── status.sh
    └── down.sh
```

## Flujo recomendado

Antes del primer arranque del stack:

```bash
cd ../bazaar-backoffice
npm install

cd ../bazaar-mobile
npm install
```

`defaults.env` es el archivo ejecutable de defaults del repo. Los scripts lo cargan con `source`.

Si necesitás overrides locales de paths o URLs, copiá `.env.local.example` como `.env.local` y ajustalo. En el caso feliz, los defaults asumen que todos los repos viven como hermanos.

`bazaar-platform` tambien deriva `GATEWAY_ALLOWED_ORIGINS` para el backend a partir de `BACKOFFICE_DEV_URL`, `MOBILE_DEV_URL` y `PLATFORM_LAN_IP`. El backend no mantiene una allowlist local hardcodeada.

Cuando `platform` detecta una IP LAN valida, `up.sh` y `status.sh` imprimen tambien la URL de API y del bundler que tenes que usar desde un dispositivo fisico.

`.env.staging.example` y `.env.production.example` son contratos documentales de ambientes futuros. No los usa ningun script local.

Defaults operativos:

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
- `PLATFORM_LAN_IP` opcional para override manual de la IP de red local

1. Validar prerequisitos:

```bash
./scripts/check.sh
```

2. Levantar backend, backoffice y mobile:

```bash
./scripts/up.sh
```

3. Revisar estado:

```bash
./scripts/status.sh
```

4. Apagar el stack:

```bash
./scripts/down.sh
```

Atajos opcionales para levantar una sola unidad:

```bash
./scripts/backoffice.sh
./scripts/mobile.sh
```

## Contrato local

- `bazaar-backend` vive como repo hermano y expone un gateway local en `LOCAL_API_BASE_URL`.
- `bazaar-backoffice` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `bazaar-mobile` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `platform` solo invoca esos entrypoints; no conoce detalles internos de `npm`, `vite` ni `expo`.
- `platform` es la unica fuente de verdad para la allowlist CORS local del gateway.

Los detalles del contrato y las decisiones postergadas estan en [docs/local-runtime.md](./docs/local-runtime.md).

La vista de ambientes, providers y consumo de API por cliente esta en [docs/environments.md](./docs/environments.md).

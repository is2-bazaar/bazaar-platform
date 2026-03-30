# bazaar-platform

Thin wrapper para correr Bazaar en desarrollo local sin duplicar infraestructura ajena.

## Objetivo

`bazaar-platform` coordina:

- el backend como una unidad local runnable
- el backoffice como dev server local
- la documentacion del contrato de entorno

No orquesta `mobile`, no resuelve cloud y no contiene logica de negocio.

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
    ├── status.sh
    └── down.sh
```

## Flujo recomendado

Antes del primer arranque del backoffice:

```bash
cd ../bazaar-backoffice
npm install
```

`defaults.env` es el archivo ejecutable de defaults del repo. Los scripts lo cargan con `source`.

Si necesitás overrides locales de paths o URLs, copiá `.env.local.example` como `.env.local` y ajustalo. En el caso feliz, los defaults asumen que todos los repos viven como hermanos.

`.env.staging.example` y `.env.production.example` son contratos documentales de ambientes futuros. No los usa ningun script local.

Defaults operativos:

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

1. Validar prerequisitos:

```bash
./scripts/check.sh
```

2. Levantar backend local:

```bash
./scripts/up.sh
```

3. Correr el backoffice:

```bash
./scripts/backoffice.sh
```

4. Revisar estado:

```bash
./scripts/status.sh
```

5. Apagar el backend:

```bash
./scripts/down.sh
```

## Contrato local

- `bazaar-backend` vive como repo hermano y expone un gateway local en `LOCAL_API_BASE_URL`.
- `bazaar-backoffice` vive como repo hermano y consume `VITE_API_BASE_URL`.
- `bazaar-mobile` queda fuera de la automatizacion, pero se documenta como parte del workspace.

Los detalles del contrato y las decisiones postergadas estan en [docs/local-runtime.md](./docs/local-runtime.md).

La vista de ambientes, providers y consumo de API por cliente esta en [docs/environments.md](./docs/environments.md).

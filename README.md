# bazaar-platform

Thin wrapper para correr Bazaar en desarrollo local sin duplicar infraestructura ajena.

## Objetivo

`bazaar-platform` coordina:

- el compose local integrado del backend
- el backoffice como dev server local
- el mobile como runtime local de Expo
- la documentacion del contrato de entorno

No resuelve cloud, no contiene logica de negocio y no es el owner de ningun deploy remoto. El deploy cloud queda para una etapa futura por repo separado.

## Estructura

```text
.
├── defaults.env
├── .env.local.example
├── .env.staging.example
├── .env.production.example
├── docs/
│   ├── adr/
│   ├── environments.md
│   └── local-runtime.md
├── infra/
│   └── compose/
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

`bazaar-platform` deriva `GATEWAY_ALLOWED_ORIGINS` para el gateway a partir de `BACKOFFICE_DEV_URL`, `MOBILE_DEV_URL` y `PLATFORM_LAN_IP`.

Cuando `platform` detecta una IP LAN valida, `up.sh` y `status.sh` imprimen tambien:

- la URL de API para el dispositivo fisico
- la probe HTTP de Metro
- la URL `exp://...` que tenes que abrir con Expo Go

`.env.staging.example` y `.env.production.example` son contratos documentales de ambientes futuros. No los usa ningun script local.

Defaults operativos:

- `ENV_NAME=local`
- `BAZAAR_BACKEND_PATH=../bazaar-backend`
- `BAZAAR_API_GATEWAY_PATH=../Bazaar-backend-api-gateway`
- `BAZAAR_AUTH_SERVICE_PATH=../bazaar-backend-auth-service`
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

- `Bazaar-backend-api-gateway` vive como repo hermano y es el source of truth del gateway.
- `bazaar-backend-auth-service` vive como repo hermano y es el source of truth del auth-service.
- `bazaar-backend` vive como repo hermano y aporta los microservicios que siguen dentro del monorepo.
- `bazaar-backoffice` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `bazaar-mobile` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `platform` es el dueño del compose local integrado del backend.
- `platform` es la unica fuente de verdad para la allowlist CORS local del gateway.

Los detalles del contrato y las decisiones postergadas estan en [docs/local-runtime.md](./docs/local-runtime.md).

La vista de ambientes, providers y consumo de API por cliente esta en [docs/environments.md](./docs/environments.md).

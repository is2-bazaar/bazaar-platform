# bazaar-platform

Thin wrapper para correr Bazaar en desarrollo local sin duplicar infraestructura ajena.

## Objetivo

`bazaar-platform` coordina:

- el compose local integrado del backend
- el backoffice como dev server local
- el mobile como runtime local de Expo
- la documentación del contrato de entorno

No resuelve cloud, no contiene lógica de negocio y no es el owner de ningún deploy remoto. El deploy cloud queda para una etapa futura por repo separado.

## Documentación y Arquitectura

- [Documentación técnica de Checkout Saga](docs/architecture/checkout-saga.md): Explica la consistencia distribuida, idempotencia, reintentos y flujo multi-vendedor del Checkout.
- [ADR 0008 - Checkout multi-vendedor](docs/adr/0008-checkout-multi-vendedor-consolidado.md)
- [ADR 0009 - Checkout Saga Architecture](docs/adr/0009-checkout-saga-architecture.md)

## Diseño y prototipos

Los prototipos de `bazaar-mobile` y `bazaar-backoffice` están disponibles en Figma:

- https://www.figma.com/design/3BjGWVlygYArP2F0e91Hfy/Bazaar?node-id=94-198&t=npY0giDu8dAYQoKw-1

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

## Layout esperado del workspace

Para que `bazaar-platform` pueda levantar el entorno local sin overrides, los repos tienen que vivir como directorios hermanos.

Ejemplo:

```text
<workspace-root>/
├── bazaar-platform/
├── Bazaar-backend-api-gateway/
├── bazaar-backend-auth-service/
├── bazaar-backend-cart-service/
├── bazaar-backend-catalog-service/
├── bazaar-backend-order-service/
├── bazaar-backend-payment-service/
├── bazaar-backend-recommendation-service/
├── bazaar-backend-user-service/
├── bazaar-backoffice/
└── bazaar-mobile/
```

Ese layout coincide con los defaults de `defaults.env`:

- `BAZAAR_API_GATEWAY_PATH=../Bazaar-backend-api-gateway`
- `BAZAAR_AUTH_SERVICE_PATH=../bazaar-backend-auth-service`
- `BAZAAR_CART_SERVICE_PATH=../bazaar-backend-cart-service`
- `BAZAAR_CATALOG_SERVICE_PATH=../bazaar-backend-catalog-service`
- `BAZAAR_ORDER_SERVICE_PATH=../bazaar-backend-order-service`
- `BAZAAR_PAYMENT_SERVICE_PATH=../bazaar-backend-payment-service`
- `BAZAAR_USER_SERVICE_PATH=../bazaar-backend-user-service`
- `BAZAAR_BACKOFFICE_PATH=../bazaar-backoffice`
- `BAZAAR_MOBILE_PATH=../bazaar-mobile`

Si algún repo vive en otra ubicación, definilo en `.env.local` para no tocar `defaults.env`.

`bazaar-platform` deriva `GATEWAY_ALLOWED_ORIGINS` para el gateway a partir de `BACKOFFICE_DEV_URL`, `MOBILE_DEV_URL` y `PLATFORM_LAN_IP`.

Cuando `platform` detecta una IP LAN válida, `up.sh` y `status.sh` imprimen también:

- la URL de API para el dispositivo físico
- la probe HTTP de Metro
- la URL `exp://...` que tenés que abrir con Expo Go

`.env.staging.example` y `.env.production.example` son contratos documentales de ambientes futuros. No los usa ningún script local.

Defaults operativos:

- `ENV_NAME=local`
- `BAZAAR_API_GATEWAY_PATH=../Bazaar-backend-api-gateway`
- `BAZAAR_AUTH_SERVICE_PATH=../bazaar-backend-auth-service`
- `BAZAAR_CART_SERVICE_PATH=../bazaar-backend-cart-service`
- `BAZAAR_CATALOG_SERVICE_PATH=../bazaar-backend-catalog-service`
- `BAZAAR_ORDER_SERVICE_PATH=../bazaar-backend-order-service`
- `BAZAAR_PAYMENT_SERVICE_PATH=../bazaar-backend-payment-service`
- `BAZAAR_RECOMMENDATION_SERVICE_PATH=../bazaar-backend-recommendation-service`
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
- `GATEWAY_LOGIN_RATE_LIMIT_WINDOW_SECONDS=60`
- `GATEWAY_LOGIN_RATE_LIMIT_MAX_REQUESTS=5`
- `GATEWAY_RECOVERY_RATE_LIMIT_WINDOW_SECONDS=900`
- `GATEWAY_RECOVERY_RATE_LIMIT_MAX_REQUESTS=5`
- `GATEWAY_RATE_LIMIT_CLEANUP_INTERVAL_SECONDS=60`
- `AUTH_LOGIN_RATE_LIMIT_WINDOW_MINUTES=15`
- `AUTH_LOGIN_RATE_LIMIT_MAX_REQUESTS=5`
- `AUTH_FORGOT_PASSWORD_RATE_LIMIT_WINDOW_MINUTES=15`
- `AUTH_FORGOT_PASSWORD_RATE_LIMIT_MAX_REQUESTS=3`
- `AUTH_RESET_PASSWORD_RATE_LIMIT_WINDOW_MINUTES=15`
- `AUTH_RESET_PASSWORD_RATE_LIMIT_MAX_REQUESTS=5`
- `CART_DB_NAME=cart_db`
- `INTERNAL_SERVICE_TOKEN` opcional en `bazaar-platform`; si queda vacío, los scripts intentan reutilizar el valor de `bazaar-backend-auth-service/.env(.local)` para mantener sincronizados `auth-service`, `catalog-service` y `user-service`
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
- `bazaar-backend-auth-service` vive como repo hermano y es el source of truth de `auth-service`.
- `bazaar-backend-cart-service` vive como repo hermano y es el source of truth de `cart-service`.
- `bazaar-backend-catalog-service` vive como repo hermano y es el source of truth de `catalog-service`.
- `bazaar-backend-order-service` vive como repo hermano y es el source of truth de `orders-service`.
- `bazaar-backend-payment-service` vive como repo hermano y es el source of truth de `payment-service`.
- `bazaar-backend-recommendation-service` vive como repo hermano y es el source of truth de `recommendation-service`. Expuesto en puerto local `18087`. Por ahora, el servicio funciona como scaffold: `/livez` y `/readyz` responden 200, los endpoints de negocio devuelven 503 Not Implemented.
- `bazaar-backend-user-service` vive como repo hermano y es el source of truth de `user-service`.
- `bazaar-platform` levanta el backend local usando solamente los repos de servicios separados.
- `bazaar-backoffice` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `bazaar-mobile` vive como repo hermano y expone `scripts/dev/{up,down,status}.sh`.
- `platform` es el dueño del compose local integrado del backend.
- `platform` es la única fuente de verdad para la allowlist CORS local del gateway.


## Tests E2E

Los scripts de integración E2E validan el sistema completo contra backend real en modo local.

### Ejecución

```bash
# Entorno local (default recomendado)
./scripts/test/integration/e2e_local.sh

# Contra Render (requiere confirmación explícita)
ALLOW_RENDER_E2E="I_UNDERSTAND_THIS_WRITES_TO_RENDER" \
  ./scripts/test/integration/e2e_render.sh
```

**Importante**: `_e2e_checkout.sh` requiere `E2E_TARGET_ENV` definido explícitamente. Ya no tiene Render como default implícito para evitar contaminar datos de producción por accidente.

### Ejecutar subconjuntos de casos

Usar `E2E_CASES` (prefijos separados por coma):

```bash
# Solo casos de readiness y checkout
E2E_TARGET_ENV=local E2E_CASES="00,20,24" ./scripts/test/integration/e2e_tests.sh

# Solo casos de cancel/refund
E2E_TARGET_ENV=local E2E_CASES="40,41,44,49" ./scripts/test/integration/e2e_tests.sh

# Solo casos de rate limiting
E2E_TARGET_ENV=local E2E_CASES="05,06,09" ./scripts/test/integration/e2e_tests.sh

# Solo casos de admin y authz
E2E_TARGET_ENV=local E2E_CASES="50,51,52,54" ./scripts/test/integration/e2e_tests.sh

# Solo casos de seguridad y perfil
E2E_TARGET_ENV=local E2E_CASES="07,08" ./scripts/test/integration/e2e_tests.sh
```

### Grupos de casos

| Prefijo | Grupo | Descripción |
|---------|-------|-------------|
| `00` | Readiness | Wake de servicios y verificación de health endpoints |
| `01-02` | Setup | Registro de actores, creación de productos semilla, seller name |
| `05` | Rate Limiting (Auth) | Rate limiting directo del auth-service para login por email |
| `06` | Recovery / non-disclosure | Forgot-password con respuesta genérica + rate limiting |
| `07` | Bloqueo de usuarios | Admin bloquea/desbloquea usuarios; acceso bloqueado rechazado |
| `08` | Privacidad de perfil | Perfil público devuelve datos minimizados; 404 para inactivos |
| `09` | Rate Limiting (Redis) | Verificación end-to-end de rate limiting con Redis |
| `10` | Cart cleanup | Limpieza de carritos vía endpoint interno |
| `20-29` | Checkout | Flujo de checkout completo, idempotencia, stock, mock payments |
| `30-38` | Órdenes | Listado de órdenes (comprador/vendedor), historial, estados |
| `40-49` | Cancelación | Cancelación de órdenes, refund, restauración de stock |
| `50-52` | Admin | Endpoints admin (users, orders), filtros, detalle read-only |
| `54` | Authz Boundaries | Verificación de fronteras de autorización a nivel gateway |
| `55` | Health Semantics | Verificación de semántica de readyz/livez en todos los servicios |

### Verificación estática (sin stack corriendo)

```bash
# Shell syntax check en todos los scripts del suite
find scripts/test/integration -name '*.sh' -exec bash -n {} \;

# ShellCheck (si está instalado)
find scripts/test/integration -name '*.sh' -exec shellcheck {} \;
```

## Limpieza de datos E2E en Render

Cuando se corren tests E2E contra Render, se crean usuarios (`u%@test.local`), productos (`SDD7_*`, `SDD9_*`), carritos, órdenes y pagos reales en las DBs de producción. Para limpiarlos de forma segura:

### Setup único

```bash
cp scripts/maintenance/.env.cleanup.example scripts/maintenance/.env.cleanup
# Editar .env.cleanup con las DATABASE_URL de cada servicio en Render
```

### Flujo de limpieza (3 fases)

```bash
# Fase 1: Dry-run — audita sin borrar nada
./scripts/maintenance/cleanup_e2e_dry_run.sh
# Revisar tmp/e2e-cleanup-dry-run-<ts>/REPORT.md

# Fase 2: Apply — borra con backup (requiere frase exacta de confirmación)
CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-<timestamp> \
CONFIRMATION="CONFIRMO BORRAR E2E RENDER" \
  ./scripts/maintenance/cleanup_e2e_apply.sh

# Fase 3: Verificar — confirma que no quedaron residuos
CLEANUP_RUN_DIR=tmp/e2e-cleanup-dry-run-<timestamp> \
  ./scripts/maintenance/cleanup_e2e_post_verify.sh
```

**Safety gates del apply**:
- Requiere `CONFIRMATION="CONFIRMO BORRAR E2E RENDER"` exacto
- Requiere `CLEANUP_RUN_DIR` apuntando a un dry-run previo
- Hace backup CSV de cada tabla antes de borrar
- Borra en orden de dependencias (order_status → orders → checkout_groups → payments → carts → reservations → products → perfiles → usuarios)

## Links a repositorios
-`Bazaar-backend-api-gateway` https://github.com/is2-bazaar/Bazaar-backend-api-gateway.git

-`Bazaar-backend-auth-service` https://github.com/is2-bazaar/bazaar-backend-auth-service.git

-`Bazaar-backend-cart-service` https://github.com/is2-bazaar/bazaar-backend-cart-service.git

-`Bazaar-backend-user-service` https://github.com/is2-bazaar/bazaar-backend-user-service.git

-`Bazaar-backend-order-service` https://github.com/is2-bazaar/bazaar-backend-order-service.git

-`Bazaar-backend-payment-service` https://github.com/is2-bazaar/bazaar-backend-payment-service.git

-`Bazaar-mobile` https://github.com/is2-bazaar/bazaar-mobile.git

-`Bazaar-backoffice` https://github.com/is2-bazaar/bazaar-backoffice.git

-`Bazaar-platform` https://github.com/is2-bazaar/bazaar-platform.git

-`Bazaar-backend-catalog-service` https://github.com/is2-bazaar/bazaar-backend-catalog-service.git

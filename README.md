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
├── .env.example
├── docs/
│   └── local-runtime.md
└── scripts/
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

Si necesitás overrides locales de paths o URLs, creá `.env.local` en este repo. En el caso feliz, los defaults de `.env.example` asumen que todos los repos viven como hermanos.

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

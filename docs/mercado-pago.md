# Mercado Pago — Integration Guide

Cómo se integra el flujo de pago entre el checkout del marketplace y Mercado Pago, incluyendo mock local, sandbox real, y troubleshooting.

## Architecture

```
Checkout → order-service → payment-service → MP preference → payment_url
                                                                    ↓
                                                              user pays
                                                                    ↓
                    order-service ← payment-service ← MP webhook ←┘
```

| Step | Actor | Action |
|------|-------|--------|
| 1 | Buyer | Clicks checkout (order-service) |
| 2 | order-service | Calls POST `payment-service` with order data |
| 3 | payment-service | Creates MercadoPago Preference → returns `payment_url` |
| 4 | Buyer | Pays on MercadoPago site (or mock resolves immediately) |
| 5 | MercadoPago | Sends webhook to `payment-service` |
| 6 | payment-service | Validates signature, updates order status, calls order-service callback |
| 7 | order-service | Finalizes order: confirms stock, cleans cart, notifies buyer |

## Mock vs MercadoPago behavior

| Scenario | mock approved | mock pending | mock rejected | mercadopago |
|----------|--------------|-------------|--------------|-------------|
| Checkout response | payment_approved, no URL | pending_payment, fake payment_url | payment_rejected | pending_payment, real sandbox URL |
| Stock | confirmed | reserved | released | reserved |
| Cart | cleaned | preserved | preserved | preserved |
| Resolution | immediate | callback/manual | immediate | webhook |

### Explanation

- **mock approved**: useful for E2E tests and local dev without external dependencies. Everything resolves instantly.
- **mock pending**: simulates the real-world flow where payment takes time. Use the `/verify` endpoint to simulate webhook completion.
- **mock rejected**: tests payment failure scenarios. Stock is released, cart preserved so buyer can retry.
- **mercadopago**: requires a sandbox account + ngrok for webhooks. Real preference creation, real MP checkout page, real webhook delivery.

## Required env vars

### payment-service

| Variable | Values | Notes |
|----------|--------|-------|
| `PAYMENT_PROVIDER` | `mock` \| `mercadopago` | Default: `mock` |
| `PAYMENT_SIMULATION_MODE` | `approved` \| `rejected` \| `pending` | Mock only. Default: `approved` |
| `MERCADOPAGO_ACCESS_TOKEN` | `TEST-xxxxx` | Sandbox tokens start with `TEST-` |
| `MERCADOPAGO_WEBHOOK_SECRET` | your-secret | Must match what's configured in MP dashboard |
| `PAYMENT_WEBHOOK_URL` | `https://...` | Must start with `https://`. ngrok URL in local dev |
| `ORDER_SERVICE_URL` | `http://orders-service:8080` | Internal Docker network address |
| `INTERNAL_SERVICE_TOKEN` | `bazaar-dev-internal-token` | Must match `order-service` |
| `PAYMENT_EXPIRATION_MINUTES` | number (default: `30`) | Preference expiration window |

### order-service

| Variable | Values | Notes |
|----------|--------|-------|
| `PAYMENT_SERVICE_URL` | `http://payment-service:8080` | Internal Docker network address |
| `CHECKOUT_SUCCESS_URL` | URL | Redirect after approved payment |
| `CHECKOUT_FAILURE_URL` | URL | Redirect after rejected payment |
| `CHECKOUT_PENDING_URL` | URL | Redirect while payment is pending |
| `INTERNAL_SERVICE_TOKEN` | `bazaar-dev-internal-token` | Must match `payment-service` |

## ngrok setup

When testing with real MercadoPago sandbox, you need a public HTTPS URL for webhook delivery:

```bash
ngrok http 18084
# Copy the HTTPS URL, e.g. https://xxxx.ngrok-free.app

PAYMENT_WEBHOOK_URL=https://xxxx.ngrok-free.app/webhooks/mercadopago
```

Then, in the MercadoPago Developers dashboard → your app → Webhooks, configure:
- **Production URL**: leave empty (sandbox only)
- **Sandbox URL**: `https://xxxx.ngrok-free.app/webhooks/mercadopago`
- **Events**: `payments`

## Local test commands

```bash
# Mock mode E2E (default)
./scripts/test/integration/e2e_local.sh

# Manual MP test — checkout
PAYMENT_PROVIDER=mercadopago \
MERCADOPAGO_ACCESS_TOKEN=TEST-xxxxx \
PAYMENT_WEBHOOK_URL=https://xxxx.ngrok-free.app/webhooks/mercadopago \
MERCADOPAGO_WEBHOOK_SECRET=mysecret \
INTERNAL_SERVICE_TOKEN=bazaar-dev-internal-token \
./scripts/test/integration/_e2e_mp_manual.sh checkout

# Manual MP test — verify (simulate webhook for pending payments)
./scripts/test/integration/_e2e_mp_manual.sh verify <CHECKOUT_GROUP_ID> <BUYER_TOKEN>
```

## Troubleshooting

| Problem | Likely cause | Fix |
|---------|-------------|-----|
| No llega webhook | ngrok not running, wrong `PAYMENT_WEBHOOK_URL`, MP dashboard not configured | Check `ngrok http 18084`, verify the HTTPS URL in env var AND MP dashboard |
| Firma inválida | `MERCADOPAGO_WEBHOOK_SECRET` mismatch or timestamp skew | Ensure the secret matches what's in MP dashboard; check server clock |
| Checkout queda `pending_payment` | Webhook never arrived | Use `verify` mode: `./scripts/test/integration/_e2e_mp_manual.sh verify <GROUP_ID> <TOKEN>` |
| order-service no recibe callback | `INTERNAL_SERVICE_TOKEN` mismatch between services | Set the same token value in both `payment-service` and `order-service` |
| Token interno incorrecto | Tokens don't match | Both services must use the exact same `INTERNAL_SERVICE_TOKEN` value |
| SandboxInitPoint vs InitPoint | MP SDK bug or unexpected response field | The gateway auto-selects; sandbox will use `SandboxInitPoint`. If it doesn't appear, check `PAYMENT_PROVIDER=mercadopago` |
| DB vieja con migraciones | Schema changed between versions | See [payment-migration.md](./payment-migration.md) for safe migration guide |
| Webhook event queda sin procesar | Processing error, event stuck | Check `webhook_events.error_message` in DB; retry is automatic for unprocessed events |

## Security

- **NEVER commit real access tokens.** Sandbox tokens (`TEST-*`) are acceptable for local dev docs, but production tokens must never enter version control.
- **Rotate** the token immediately if it's ever exposed (committed, shared, logged).
- **Local dev**: always use `TEST-` tokens from sandbox.
- **Production**: use Render secrets or env groups — never hardcoded, never in `.env` files.

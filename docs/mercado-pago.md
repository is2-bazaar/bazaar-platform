# Mercado Pago Integration

## Local Development (Mock Mode)
The default configuration uses mock mode. No real Mercado Pago account needed.
- `PAYMENT_PROVIDER=mock` (default)
- `PAYMENT_SIMULATION_MODE=approved` (default, can be `rejected` or `pending`)
All E2E tests work with mock mode.

## Testing with Mercado Pago Sandbox

### Prerequisites
1. Mercado Pago developer account (https://www.mercadopago.com.ar/developers)
2. Sandbox access token from MP dashboard
3. ngrok or cloudflared for webhook delivery

### Setup
1. Start ngrok: `ngrok http 18084`
2. Copy the HTTPS URL (e.g., `https://abc123.ngrok.io`)
3. Update your `.env.local`:
   ```
   PAYMENT_PROVIDER=mercadopago
   MERCADOPAGO_ACCESS_TOKEN=TEST-xxxxx
   PAYMENT_WEBHOOK_URL=https://abc123.ngrok.io/webhooks/mercadopago
   MERCADOPAGO_WEBHOOK_SECRET=your-secret
   ```
4. Restart: `docker compose up -d payment-service orders-service`

### Testing Flow
1. Use test credit cards from MP sandbox docs
2. Checkout will return a `payment_url` → open in browser
3. Complete payment with test cards
4. Webhook will trigger order confirmation automatically

### Important
- NEVER commit real access tokens
- Sandbox tokens start with `TEST-`
- Webhook delivery requires a public URL (ngrok/cloudflared)

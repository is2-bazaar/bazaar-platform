# ADR 0009 - Saga de checkout orquestada por order-service

## Status

Accepted / Implemented

## Contexto

ADR 0008 fijó la decisión de producto principal: una compra visible para el comprador y una orden operativa por vendedor, todas agrupadas por `checkout_group_id`.

Faltaba cerrar CÓMO se sostiene esa compra multi-vendedor de forma consistente cuando intervienen varios servicios:

- `order-service`
- `cart-service`
- `catalog-service`
- `payment-service`
- `API Gateway`

La implementación real confirma que Bazaar resuelve esto con una Saga síncrona orquestada por `order-service`.

## Decisión

Se adopta una **Saga orquestada por `order-service`** para el checkout multi-vendedor.

Reglas centrales de la decisión:

1. El comprador inicia un único `POST /checkout` con `Idempotency-Key` y `delivery_address`.
2. `order-service` crea o recupera un `checkout_group_id` usando `(buyer_id, idempotency_key)`.
3. `order-service` crea una orden por `seller_id`.
4. `catalog-service` reserva stock antes del pago.
5. `payment-service` procesa un único pago por `checkout_group_id`.
6. Si el pago es aprobado, `catalog-service` confirma la reserva existente y `order-service` confirma las órdenes.
7. Si el pago es rechazado, `order-service` libera la reserva y deja las órdenes en `pago rechazado`.
8. El cleanup del carrito ocurre al final y resta solo cantidades compradas.

## Contratos Verificados

### Entrada pública

`POST /checkout`

- auth: JWT vía API Gateway
- header requerido: `Idempotency-Key`
- body real: `delivery_address`, `delivery_city`, `delivery_province`, `coupon_code`
- required real: `delivery_address`
- response real: `201 Created`

### Reconciliación pública

- `GET /checkout/attempts/{idempotencyKey}`
- `GET /checkout-groups/{checkoutGroupId}`

Ambos endpoints son read-only y no disparan side effects.

### Reserva de stock

`POST /internal/stock/reservations`

- auth: `X-Internal-Service-Token`
- request real: `checkout_group_id`, `items[]` con `product_id` numérico y `quantity`
- success real: `201 Created`
- idempotencia real: unique sobre `stock_reservations.checkout_group_id`

### Confirmación de stock

`POST /internal/stock/reservations/{checkoutGroupId}/confirm`

- auth: `X-Internal-Service-Token`
- success real: `200 OK`
- semántica real: **no** descuenta stock otra vez; confirma la reserva ya descontada
- idempotencia real: por estado (`confirmed` es no-op)

### Liberación de stock

`POST /internal/stock/reservations/{checkoutGroupId}/release`

- auth: `X-Internal-Service-Token`
- success real: `200 OK`
- semántica real: restaura stock solo si la reserva estaba en `reserved`
- idempotencia real: por estado (`released` es no-op, `confirmed` da conflicto)

### Pago

`POST /internal/payments`

- auth: `X-Internal-Service-Token`
- header requerido: `Idempotency-Key`
- request real: `checkout_group_id`, `buyer_id`, `amount_cents`, `currency`, `items[]`, URLs de retorno
- success real: `201 Created`
- rechazo real: body `status: "rejected"`, NO `HTTP 402`
- idempotencia real: por header y por unique `checkout_group_id`

### Refund técnico

`POST /internal/payments/{paymentId}/refund`

- auth: `X-Internal-Service-Token`
- header requerido: `Idempotency-Key`
- success real: `201 Created`
- request body real: no obligatorio para ejecutar la operación
- transición real en `payment-service`: `approved -> refund_pending -> refunded` cuando el gateway responde bien
- callback real: `payment-service` notifica a `order-service` con `POST /internal/checkout-groups/{checkoutGroupId}/mark-payment-refunded`

### Cleanup de carrito

`POST /internal/checkout-cleanup`

- auth: `X-Internal-Service-Token`
- request real: `buyer_id`, `checkout_group_id`, `items[]`
- success real: `200 OK`
- idempotencia real: tabla `cart_cleanup_operations`, unique por `checkout_group_id`
- semántica real: decrementa o elimina solo cantidades compradas

## Invariantes Arquitectónicos

La implementación real sostiene estas garantías:

- no doble cobro por replay del mismo checkout;
- no doble descuento de stock;
- no doble venta del último ítem;
- separación fuerte entre compra visible y órdenes por vendedor;
- cleanup selectivo del carrito;
- reconciliación por `Idempotency-Key` y por `checkout_group_id`.

## Idempotencia

| Capa | Mecanismo real |
|---|---|
| Checkout público | unique `(buyer_id, idempotency_key)` en `checkout_groups` |
| Órdenes por seller | unique `(checkout_group_id, seller_id)` |
| Reserva de stock | unique `stock_reservations.checkout_group_id` |
| Confirm/release stock | control por estado de la reserva |
| Pago | header `Idempotency-Key` + unique `payments.checkout_group_id` |
| Cleanup carrito | unique `cart_cleanup_operations.checkout_group_id` |

## Consecuencias

### Positivas

- Mantiene UX de compra única sin mezclar operación entre vendedores.
- Centraliza la consistencia distribuida en el servicio que ya conoce órdenes y `checkout_group_id`.
- Permite reintentos seguros y reconciliación explícita.
- Ubica la protección crítica de concurrencia en `catalog-service`, dueño del stock.

### Negativas

- `order-service` queda como coordinador crítico del flujo.
- La Saga es síncrona y depende de varios servicios HTTP.
- El refund técnico existe a nivel de `payment-service`, pero su uso automático desde `order-service` todavía no está completamente cableado en runtime.
- El estado E2E real hoy está más maduro en backend que en mobile/backoffice.

## Drift Corregido

Durante esta revisión contra código real se corrigieron estos puntos que estaban mal documentados:

1. `POST /checkout` devuelve `201`, no `200`.
2. `CheckoutRequest` usa `delivery_*`, no `shipping_address/city/province`.
3. `POST /checkout/quote` existe y funciona; no es un stub `501`.
4. El cleanup real es `POST /internal/checkout-cleanup`, no `/internal/carts/{buyerId}/clear-purchased-items`.
5. `catalog-service` descuenta en `reserve`; `confirm` no vuelve a descontar.
6. El rechazo de pago es estado de negocio en body, no `HTTP 402`.
7. `product_id` en checkout/cart/stock es numérico, no UUID.
8. No existe un endpoint dedicado `/admin/checkout-groups/:id`; el acceso administrativo real usa `GET /checkout-groups/:id` con rol `admin`.
9. Buyer `GET /orders` sí soporta filtro por `status`.
10. El refund técnico puede llegar a `refunded` en `payment-service`; lo que sigue parcial es el disparo automático end-to-end desde `order-service`.

## Fuera de alcance

Esta ADR no decide:

- la UI final de mobile o backoffice;
- integración productiva obligatoria con Mercado Pago;
- cupones funcionales en checkout;
- jobs asíncronos de retry/backoff/circuit breaker.

## Referencias

- [ADR 0008 - Checkout multi-vendedor con órdenes por vendedor agrupadas](./0008-checkout-multi-vendedor-consolidado.md)
- [Arquitectura del Checkout Saga](../architecture/checkout-saga.md)

# ADR 0009 - Checkout Saga Architecture

## Status

Accepted / Implemented (Actualizado post-SDD9 — Mayo 2026)

## Correcciones post-implementación (Mayo 2026)

Tras inspeccionar el código real de todos los servicios (SDD0–SDD9 mergeados), se corrigieron las siguientes discrepancias entre el ADR original y lo implementado:

1. **Cart cleanup endpoint**: El path real es `POST /internal/checkout-cleanup`, no `/internal/carts/{buyerId}/clear-purchased-items`. La idempotencia se basa en un unique index sobre `cart_cleanup_operations.checkout_group_id` con `ON CONFLICT DO NOTHING`, no en un header `Idempotency-Key`.
2. **CheckoutGroup estados**: El modelo real tiene 12 estados (`pending_stock`, `pending_payment`, `payment_approved`, `payment_rejected`, `compensating`, `failed`, `confirmed`, `preparing`, `shipped`, `delivered`, `cancelled`, `completed`) más 6 campos de progreso granular. El ADR original solo mencionaba 5.
3. **Payment rejected**: No retorna HTTP 402. Payment-service crea el payment con `status: "rejected"` y retorna HTTP 201. El manejo de compensación (release de stock) lo ejecuta order-service.
4. **Refund**: El endpoint `POST /internal/payments/{paymentId}/refund` existe y es funcional, pero solo transiciona a `refund_pending`. La transición a `refunded` no está implementada (sin webhook asíncrono).
5. **Órdenes post-checkout**: Las órdenes quedan en `confirmada` después del checkout exitoso, no en `en preparación`. Los estados de fulfillment se alcanzan vía endpoints de seller/comprador.
6. **Cart DB**: PostgreSQL exclusivamente. No se usa Redis en producción.
7. **Sin backoff/circuit breaker**: La idempotencia es la única red de seguridad ante reintentos. No hay retry automático con backoff.

## Context

ADR 0008 establishes the multi-vendor checkout model: one visible purchase group for the buyer, one operational order per seller, unified by `checkout_group_id`. ADR 0008 is the immutable baseline — this ADR does NOT modify it.

ADR 0008 leaves the consistency strategy open: "es aceptable una orquestación simple desde `order-service`, siempre que sea idempotente y maneje errores explícitamente." This ADR closes that gap by defining:

1. An explicit **saga orchestration** model where `order-service` is the central orchestrator.
2. Concrete **internal service contracts** for stock reservation, payment, and cart cleanup.
3. **Idempotency rules** — both public (buyer-facing) and internal (service-to-service).
4. A **phased delivery sequence** (SDD0–SDD10) that decomposes the saga into incremental, verifiable increments.

Without these definitions, each service team would interpret ADR 0008 differently, leading to divergent contracts, inconsistent error handling, and integration failures at the saga level.

## Decision

The checkout flow is a **saga orchestrated by `order-service`**. The saga progresses through sequential steps — stock reservation, payment, stock confirmation, cart cleanup — with compensating actions (stock release, technical refund) on failure. `order-service` owns the state machine and coordinates all downstream service calls.

## Canonical Terms

| Term | Definition |
|------|-----------|
| **CheckoutGroup** | A single buyer's checkout intent, identified by `checkout_group_id`. It ties together multiple orders (one per seller) and a single payment intent. |
| **Order** | A purchase agreement between a buyer and a *single* seller. A `CheckoutGroup` has N `Order`s. |
| **StockReservation** | A temporary hold on inventory for items in a `CheckoutGroup` pending payment confirmation. All-or-nothing per group. |
| **Payment** | A single financial transaction covering the sum of all orders in a `CheckoutGroup`. |
| **CartCleanup** | The process of selectively removing only purchased quantities of items from a cart post-payment, preserving later additions. NOT a clear-all operation. |
| **SagaStatus** | The aggregate state of the distributed transaction: `pending_stock`, `pending_payment`, `payment_approved`, `payment_rejected`, `compensating`, `failed`, `confirmed`, `preparing`, `shipped`, `delivered`, `cancelled`, `completed`. The CG also persists granular progress fields: `PaymentStatus`, `StockReservationStatus`, `StockConfirmationStatus`, `OrdersConfirmationStatus`, `CartCleanupStatus`, `LastError`. |
| **Technical Refund** | A compensatory action inside a saga to revert a successful payment if a subsequent saga step fails. NOT a user-facing product return or cancellation feature. |

## Saga Orchestration Flow

`order-service` is the single orchestrator for the checkout saga. The normal flow is:

```text
1. Buyer initiates checkout (POST /checkout with idempotency_key)
   → order-service resolves or creates checkout_group_id via public idempotency

2. order-service calls catalog-service:
   POST /internal/stock/reservations  (reserve stock for all items)

3. On reservation success, order-service calls payment-service:
   POST /internal/payments  (single payment intent per checkout_group_id)

4a. On payment approved:
   → order-service calls catalog-service:
     POST /internal/stock/reservations/{checkoutGroupId}/confirm
   → order-service calls cart-service:
      POST /internal/checkout-cleanup
    → all orders in the group advance to "confirmada"

 4b. On payment rejected or downstream failure:
    → order-service calls catalog-service:
      POST /internal/stock/reservations/{checkoutGroupId}/release
    → if payment was already processed, order-service calls payment-service:
      POST /internal/payments/{paymentId}/refund  (technical compensatory refund)
    → all orders in the group move to "pago rechazado" or "fallida"
    → saga status = compensating → payment_rejected
```

The saga is strictly sequential: Reserve → Pay → Confirm/Cleanup. No step executes before its predecessor succeeds. Compensation runs in reverse order of completed steps.

## Public Idempotency

Public idempotency ensures that replaying checkout with the same key produces no side effects:

```text
buyer_id + idempotency_key => checkout_group_id
```

- If the combination already exists, `order-service` returns the existing `checkout_group_id` and its current state.
- If the combination is new, `order-service` creates a new `checkout_group_id` and begins the saga.
- The `idempotency_key` is provided by the client on `POST /checkout` via the `Idempotency-Key` header.

## Internal Idempotency Keys

Each internal service call uses an idempotency key derived from `checkout_group_id` to prevent duplicate side effects on retry:

| Internal Call | Idempotency-Key Value |
|--------------|----------------------|
| `POST /internal/stock/reservations` | `{checkout_group_id}` |
| `POST /internal/stock/reservations/{checkoutGroupId}/confirm` | `confirm-{checkout_group_id}` |
| `POST /internal/stock/reservations/{checkoutGroupId}/release` | `release-{checkout_group_id}` |
| `POST /internal/payments` | `payment-{checkout_group_id}` |
| `POST /internal/payments/{paymentId}/refund` | `refund-{checkout_group_id}` |
| `POST /internal/checkout-cleanup` | `{checkout_group_id}` |

## Internal Service Contracts

All internal endpoints require the `X-Internal-Service-Token` header for service-to-service authentication. No `Authorization` (Bearer JWT) header is used on internal paths.

### 1. Stock Reservation (catalog-service)

#### POST /internal/stock/reservations

Reserves stock for all items in a checkout group. All-or-nothing: if any item has insufficient stock, the entire reservation fails.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency-Key | `{checkout_group_id}` |
| Request Body | `StockReservationRequest` |
| Success Response | `200 OK` |
| Error Response | `409 Conflict` — `StockInsufficientError` |

Request body:

```json
{
  "checkout_group_id": "uuid",
  "items": [
    {
      "product_id": "uuid",
      "quantity": 2,
      "seller_id": "uuid"
    }
  ]
}
```

#### POST /internal/stock/reservations/{checkoutGroupId}/confirm

Confirms a previously successful reservation after payment is approved. Deducts reserved stock permanently.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency-Key | `confirm-{checkout_group_id}` |
| Path Param | `checkoutGroupId` (UUID) |
| Success Response | `200 OK` |

#### POST /internal/stock/reservations/{checkoutGroupId}/release

Releases a previously successful reservation on payment rejection or saga compensation. Returns reserved stock to available inventory.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency-Key | `release-{checkout_group_id}` |
| Path Param | `checkoutGroupId` (UUID) |
| Success Response | `200 OK` |

### 2. Payment (payment-service)

#### POST /internal/payments

Creates a single payment intent for the entire checkout group.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency-Key | `payment-{checkout_group_id}` |
| Request Body | `PaymentCreateRequest` |
| Success Response | `200 OK` — `PaymentCreateResponse` |
| Error Response | `402 Payment Required` / `4xx` |

Request body:

```json
{
  "checkout_group_id": "uuid",
  "amount": 18000.00,
  "buyer_id": "uuid",
  "idempotency_key": "payment-{checkout_group_id}"
}
```

Response body:

```json
{
  "payment_id": "uuid",
  "status": "approved",
  "checkout_group_id": "uuid"
}
```

#### POST /internal/payments/{paymentId}/refund

Technical compensatory refund only — used when the saga needs to revert a successful payment due to a downstream failure. This is NOT the user-facing product cancellation/refund feature.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency-Key | `refund-{checkout_group_id}` |
| Path Param | `paymentId` (UUID) |
| Request Body | `TechnicalRefundRequest` |
| Success Response | `200 OK` |

Request body:

```json
{
  "checkout_group_id": "uuid",
  "reason": "saga_compensation"
}
```

### 3. Cart Cleanup (cart-service)

#### POST /internal/checkout-cleanup

Removes only the purchased quantities of items from the buyer's cart. This is NOT a clear-all operation — items added to the cart after checkout started are preserved. If a cart item's purchased quantity equals or exceeds its cart quantity, the item is removed (hard delete via `Unscoped()`). If the purchased quantity is less than the cart quantity, only the purchased quantity is subtracted.

Idempotency is enforced via a `cart_cleanup_operations` table with a unique index on `checkout_group_id`. The first INSERT wins (`ON CONFLICT DO NOTHING`); subsequent calls with the same `checkout_group_id` see `RowsAffected == 0` and return immediately without touching cart items.

The operation runs in a single database transaction: (1) idempotency guard insert, (2) `SELECT ... FOR UPDATE` on matching cart items, (3) hard delete or quantity decrement.

| Property | Value |
|----------|-------|
| Auth | `X-Internal-Service-Token` |
| Idempotency | Unique index on `checkout_group_id` in `cart_cleanup_operations` |
| Request Body | `CleanupCartRequest` (`buyer_id`, `checkout_group_id`, `items[]`) |
| Success Response | `200 OK` |

Request body:

```json
{
  "buyer_id": 42,
  "checkout_group_id": "uuid",
  "items": [
    {
      "product_id": 1,
      "quantity": 2
    }
  ]
}
```

**Important**: Cart cleanup uses `POST`, never `DELETE` with a body. `DELETE` with a request body has ambiguous semantics and poor HTTP client support. The endpoint is idempotent at the database level (unique constraint on `cart_cleanup_operations.checkout_group_id`), not via a header-based idempotency key.

## Public Reconciliation Endpoints

These endpoints allow the frontend to recover checkout state after disconnections, timeouts, or page refreshes.

### GET /checkout/attempts/{idempotencyKey}

Returns the `CheckoutGroup` associated with a given idempotency key for the authenticated buyer.

| Property | Value |
|----------|-------|
| Auth | `Authorization: Bearer {JWT}` |
| Path Param | `idempotencyKey` (string) |
| Success Response | `200 OK` — `CheckoutGroupResponse` |
| Not Found Response | `404 Not Found` |

### GET /checkout-groups/{checkoutGroupId}

Returns the full `CheckoutGroup` detail for the authenticated buyer.

| Property | Value |
|----------|-------|
| Auth | `Authorization: Bearer {JWT}` |
| Path Param | `checkoutGroupId` (UUID) |
| Success Response | `200 OK` — `CheckoutGroupResponse` |
| Not Found Response | `404 Not Found` |

### API Gateway Routing

The API Gateway MUST route reconciliation endpoints to `order-service`:

```text
GET /checkout/attempts/{idempotencyKey}  → order-service
GET /checkout-groups/{checkoutGroupId}   → order-service
POST /checkout                           → order-service
```

The Gateway applies JWT validation before forwarding. Internal endpoints (`/internal/*`) are NOT exposed through the API Gateway — they are service-to-service only, authenticated via `X-Internal-Service-Token`.

## PR/SDD Sequencing

The saga architecture is delivered in 10 incremental phases. Each SDD is independently verifiable and builds on the previous one.

| Phase | SDD | Description |
|-------|-----|-------------|
| 0 | SDD0 | Docs: ADR 0009 + OpenAPI stub (this phase — architecture and contracts only) |
| 1 | SDD1 | Checkout groups + idempotency — order model gains `checkout_group_id`; public idempotency (buyer_id + idempotency_key → checkout_group_id) |
| 2 | SDD2 | One order per seller — checkout splits cart by `seller_id`, creates N orders per group |
| 3 | SDD3 | Catalog stock reservation — `POST /internal/stock/reservations` with all-or-nothing batch |
| 4 | SDD4 | Order-service integrates reservation — calls reserve before payment, confirm/release on saga completion |
| 5 | SDD5 | Payment by group — single payment per `checkout_group_id` with `payment-{checkout_group_id}` idempotency |
| 6 | SDD6 | Continuation post-payment — order-service handles payment callback, advances order states |
| 7 | SDD7 | Stock/order confirmation — confirm and release wired; order status updated after payment outcome |
| 8 | SDD8 | Cart cleanup — `POST /internal/checkout-cleanup` integrated into saga |
| 9 | SDD9 | Reconciliation + gateway — `GET /checkout/attempts/:idempotencyKey` and `GET /checkout-groups/:checkoutGroupId` via API Gateway |
| 10 | SDD10 | Seller/admin privacy — seller sees own orders only; admin sees all with group view |

## Consequences

### Positive

- Explicit saga orchestration makes the checkout flow debuggable and testable at each step.
- Internal contracts with idempotency keys prevent duplicate side effects across service retries.
- Cart cleanup by purchased quantities (not clear-all) preserves items the buyer added during checkout.
- Single payment per group matches the buyer's mental model of one purchase.
- Phased delivery (SDD0–SDD10) reduces integration risk and enables incremental verification.

### Negative

- `order-service` becomes a central dependency — if it's down, checkout is down. This is acceptable given the current scale; choreography can be reconsidered if order-service becomes a bottleneck.
- Eventual consistency between services: stock may be reserved but payment may fail, requiring compensation. The saga handles this, but operators must monitor for stuck sagas.
- Internal idempotency keys must be derived deterministically from `checkout_group_id` — any deviation risks duplicate side effects.
- Technical refund is saga-scoped only; full cancellation/refund features are deferred to future work.

## Out of Scope

The following are explicitly out of scope for this ADR and the SDD0–SDD10 sequence defined here:

- Business code implementation (handlers, repositories, services)
- Database migrations
- Functional tests
- Full user-facing cancellation/refund feature
- Payment provider integration specifics
- Gateway routing implementation
- Admin/seller UI changes

These items may be addressed in future SDDs beyond SDD10 or in separate change proposals.

## References

- ADR 0008: Checkout multi-vendedor con órdenes por vendedor agrupadas (read-only baseline)
- [Documentación técnica del Checkout Saga](../architecture/checkout-saga.md)

## Relación con el enunciado del TP
Esta decisión implementa y cubre directamente requerimientos del TP Bazaar de IS2:
- **Consistencia distribuida / APIs:** Implementando una Saga y evitando transacciones de base de datos distribuidas (2PC).
- **Control de concurrencia:** El catálogo maneja transacciones de BD para no vender de más, en un contexto distribuido.
- **Idempotencia:** Evita el doble pago usando la clave `payment-{checkout_group_id}` requerida.
- **Manejo de errores:** Compensación de stock mediante `/release` en caso de fallos de pago.
- **Microservicios independientes:** Bases separadas por servicio y comunicación vía API Gateway / eventos síncronos HTTP.

## Bugs corregidos / Aprendizajes de la Implementación
1. **Doble limpieza de carrito en reintentos tardíos**: Se observó que un retry muy lento borraba ítems que el usuario acababa de agregar. Se solucionó introduciendo la tabla `cart_cleanup_operations` y restando solo las *cantidades* abonadas en vez de hacer un "clear all".
2. **Race condition del último ítem**: Operaciones de check de stock en memoria dejaban pasar race conditions; se movió la lógica a `SELECT FOR UPDATE` transaccional en `catalog-service`.
3. **Privacidad del seller**: Un seller podía acceder a órdenes hermanas del mismo `CheckoutGroup`. Se solucionó aplicando chequeos estrictos de ownership contra `orders.seller_id` y retornando `404` en caso de mismatch para evitar enumeración (implementado en SDD9).

# Checkout Saga

> Editar diagramas: https://mermaid.live

Documentación verificada contra la implementación real en:

- `bazaar-platform`
- `bazaar-backend-order-service`
- `bazaar-backend-catalog-service`
- `bazaar-backend-payment-service`
- `bazaar-backend-cart-service`
- `Bazaar-backend-api-gateway`
- `bazaar-mobile`
- `bazaar-backoffice`

## Resumen

El checkout de Bazaar está implementado como una Saga orquestada por `order-service`.

- el comprador ve una compra consolidada;
- internamente se crea una orden por vendedor dentro de un `checkout_group_id`;
- el pago es único por `checkout_group_id`;
- el stock se reserva antes de intentar cobrar;
- `confirm` no descuenta stock otra vez: solo confirma una reserva ya descontada;
- el cleanup del carrito no hace `clear all`: resta únicamente las cantidades compradas.

## Alcance E2E real

- El flujo backend real hoy pasa por `API Gateway -> order-service -> cart-service -> catalog-service -> payment-service`.
- `bazaar-mobile` NO tiene checkout integrado end-to-end: `src/app/(tabs)/cart.tsx` renderiza `HomeScreen`, o sea, el tab de carrito es un placeholder.
- `bazaar-backoffice` sigue parcial para órdenes/métricas: `src/services/adminService.ts` usa mocks (`ADMIN_ORDERS`, `ORDERS_EVOLUTION_BARS`).
- Para el TP, el alcance defendible hoy es backend + gateway reales, con frontends todavía parciales para el circuito completo de compra.

## Flujo Feliz

```mermaid
sequenceDiagram
    autonumber
    actor Buyer as Buyer / Mobile
    participant Gateway as API Gateway
    participant Order as order-service
    participant Cart as cart-service
    participant Catalog as catalog-service
    participant Payment as payment-service

    Buyer->>Gateway: POST /checkout\nAuthorization + Idempotency-Key\ndelivery_address
    Gateway->>Order: Forward con identidad validada
    Order->>Order: FindOrCreateCheckoutGroup(buyer_id, idempotency_key)
    Order->>Cart: GET /cart
    Cart-->>Order: carrito actual
    Order->>Catalog: Validaciones read-only por producto
    Catalog-->>Order: disponibilidad preliminar
    Order->>Order: Crear N órdenes, una por seller
    Order->>Catalog: POST /internal/stock/reservations
    Catalog-->>Order: 201 reserved
    Order->>Payment: POST /internal/payments\nIdempotency-Key: payment-{checkout_group_id}
    Payment-->>Order: 201 approved | pending | rejected
    Order->>Catalog: POST /internal/stock/reservations/{checkoutGroupId}/confirm
    Catalog-->>Order: 200 confirmed
    Order->>Order: Confirmar órdenes hijas
    Order->>Cart: POST /internal/checkout-cleanup
    Cart-->>Order: 200 ok
    Order-->>Gateway: 201 Created + CheckoutResponse
    Gateway-->>Buyer: compra consolidada
```

### Notas verificadas

- El comprador ve una sola compra, pero el backend persiste una orden por vendedor.
- `order-service` agrupa todo bajo un único `checkout_group_id`.
- `payment-service` aplica idempotencia por header `Idempotency-Key` y además por `checkout_group_id`.
- `catalog-service` descuenta stock en `reserve`; `confirm` solo cambia `reserved -> confirmed`.
- `cart-service` limpia cantidades compradas por `product_id`; si el usuario volvió a agregar el mismo producto durante el checkout, solo se resta lo comprado.
- `POST /checkout` responde `201 Created`, incluso cuando el request es un replay con la misma `Idempotency-Key`.

## Flujos Alternativos Obligatorios

### 1. Stock insuficiente

El checkout falla antes del pago.

- `order-service` obtiene carrito y arma el intento.
- `catalog-service` rechaza `POST /internal/stock/reservations` con `409`.
- `payment-service` NO es llamado.
- el carrito queda intacto;
- el frontend recibe `409 Conflict`.

```mermaid
sequenceDiagram
    autonumber
    actor Buyer
    participant Gateway as API Gateway
    participant Order as order-service
    participant Cart as cart-service
    participant Catalog as catalog-service

    Buyer->>Gateway: POST /checkout
    Gateway->>Order: forward
    Order->>Cart: GET /cart
    Cart-->>Order: carrito
    Order->>Catalog: POST /internal/stock/reservations
    Catalog-->>Order: 409 insufficient_stock_items
    Order-->>Gateway: 409 Conflict
    Gateway-->>Buyer: checkout rechazado sin pago
```

Observación importante:
La implementación real ya puede haber creado el `checkout_group` y las órdenes hijas antes del intento de reserva. Lo que NO ocurre es el pago ni una compra confirmada visible.

### 2. Pago rechazado

El rechazo es un resultado de negocio, no un `HTTP 402`.

- el stock ya estaba reservado;
- `payment-service` responde `201` con body `status: "rejected"`;
- `order-service` libera la reserva con `POST /internal/stock/reservations/{checkoutGroupId}/release`;
- las órdenes quedan en `pago rechazado`;
- el carrito queda intacto;
- el `CheckoutResponse` vuelve con `status: "payment_rejected"`.

```mermaid
sequenceDiagram
    autonumber
    actor Buyer
    participant Gateway as API Gateway
    participant Order as order-service
    participant Catalog as catalog-service
    participant Payment as payment-service

    Buyer->>Gateway: POST /checkout
    Gateway->>Order: forward
    Order->>Catalog: reserve stock
    Catalog-->>Order: 201 reserved
    Order->>Payment: POST /internal/payments
    Payment-->>Order: 201 { status: rejected }
    Order->>Catalog: POST /internal/stock/reservations/{checkoutGroupId}/release
    Catalog-->>Order: 200 released
    Order->>Order: marcar órdenes pago rechazado
    Order-->>Gateway: 201 { status: payment_rejected }
    Gateway-->>Buyer: pago rechazado
```

### 3. Concurrencia por último ítem

La protección real está en `catalog-service`, no en el chequeo preliminar de disponibilidad.

- dos buyers pueden pasar `validateAvailability` al mismo tiempo;
- `catalog-service` ordena `product_id` y lockea filas con `SELECT FOR UPDATE`;
- uno reserva y descuenta stock;
- el otro espera el lock y luego recibe `409`;
- no hay doble venta del último ítem.

```mermaid
sequenceDiagram
    autonumber
    actor BuyerA
    actor BuyerB
    participant Order as order-service
    participant Catalog as catalog-service

    par Intento A
        BuyerA->>Order: POST /checkout
        Order->>Catalog: reserve(product X, qty 1)
        Catalog->>Catalog: SELECT ... FOR UPDATE
        Catalog-->>Order: 201 reserved
    and Intento B
        BuyerB->>Order: POST /checkout
        Order->>Catalog: reserve(product X, qty 1)
        Catalog->>Catalog: espera lock del mismo producto
        Catalog-->>Order: 409 insufficient_stock_items
    end
```

### 4. Retry por timeout

Con la misma `Idempotency-Key` no se duplican órdenes, stock ni pago.

- `order-service` resuelve el mismo `checkout_group_id` por `(buyer_id, idempotency_key)`;
- si ya había órdenes, reanuda o devuelve el estado actual;
- `catalog-service` es idempotente por `checkout_group_id`;
- `payment-service` es idempotente por header y por `checkout_group_id`;
- el frontend puede reconciliar con:
  - `GET /checkout/attempts/:idempotencyKey`
  - `GET /checkout-groups/:checkoutGroupId`

```mermaid
sequenceDiagram
    autonumber
    actor Buyer
    participant Gateway as API Gateway
    participant Order as order-service
    participant Catalog as catalog-service
    participant Payment as payment-service

    Buyer->>Gateway: POST /checkout (key K)
    Gateway->>Order: intento original
    Order->>Catalog: reserve
    Order->>Payment: create payment
    Note over Buyer,Gateway: timeout o respuesta perdida
    Buyer->>Gateway: POST /checkout (misma key K)
    Gateway->>Order: replay idempotente
    Order->>Order: reusar checkout_group existente
    Order-->>Gateway: 201 con estado actual
    Buyer->>Gateway: GET /checkout/attempts/K
    Gateway->>Order: consulta read-only
    Order-->>Gateway: estado actual
```

### 5. Pago pendiente (estado `pending_payment`)

El flujo ocurre cuando `payment-service` responde `201` con `status: "pending"`. El comprador es redirigido al provider externo para completar el pago.

- el stock ya está reservado;
- las órdenes quedan en `pendiente de pago`;
- el carrito NO se limpia todavía;
- `order-service` responde `201 { status: pending_payment, payment_url }`;
- el comprador debe completar el pago en el provider externo.

```mermaid
sequenceDiagram
    autonumber
    actor Buyer as Buyer / Mobile
    participant Gateway as API Gateway
    participant Order as order-service
    participant OrderDB as Order DB
    participant Cart as cart-service
    participant CartDB as Cart DB
    participant Catalog as catalog-service
    participant CatalogDB as Catalog DB
    participant Payment as payment-service
    participant PaymentDB as Payment DB

    Buyer->>Gateway: POST /checkout<br/>JWT + Idempotency-Key
    Gateway->>Order: POST /checkout<br/>X-User-ID

    Order->>OrderDB: FindOrCreate CheckoutGroup<br/>(buyer_id + idempotency_key)

    Order->>Cart: GET /cart
    Cart->>CartDB: Read buyer cart
    Cart-->>Order: Cart items

    Order->>Catalog: Validate product availability
    Catalog->>CatalogDB: Read products / stock
    Catalog-->>Order: Availability OK

    Order->>OrderDB: Create one Order per seller<br/>status = pendiente de pago

    Order->>Catalog: POST /internal/stock/reservations
    Catalog->>CatalogDB: SELECT FOR UPDATE products
    Catalog->>CatalogDB: Deduct stock + create reservation<br/>status = reserved
    Catalog-->>Order: Reservation reserved

    Order->>OrderDB: Update stock_reservation_status = reserved

    Order->>Payment: POST /internal/payments<br/>Idempotency-Key: payment-{checkout_group_id}
    Payment->>PaymentDB: Create or return existing payment
    Payment-->>Order: Payment status = pending<br/>payment_url

    Order->>OrderDB: Save payment_id<br/>payment_status = pending<br/>checkout_group.status = pending_payment

    Order-->>Gateway: 201 CheckoutResponse<br/>status = pending_payment<br/>payment_url
    Gateway-->>Buyer: Continue payment in provider

    Note over Order,Catalog: Stock remains reserved while payment is pending.
    Note over Order,Cart: Cart is not cleaned yet.
    Note over Order,OrderDB: Orders remain pendiente de pago.
```

### 6. Pago aprobado (estado `payment_approved`)

El flujo ocurre cuando `payment-service` responde `201` con `status: "approved"`. El pago se concreta inmediatamente.

- el stock ya estaba reservado;
- se confirma la reserva (`reserved -> confirmed`);
- las órdenes pasan a `confirmada`;
- se limpia el carrito;
- `order-service` responde `201 { status: confirmed }`.

```mermaid
sequenceDiagram
    autonumber
    actor Buyer as Buyer / Mobile
    participant Gateway as API Gateway
    participant Order as order-service
    participant OrderDB as Order DB
    participant Cart as cart-service
    participant CartDB as Cart DB
    participant Catalog as catalog-service
    participant CatalogDB as Catalog DB
    participant Payment as payment-service
    participant PaymentDB as Payment DB

    Buyer->>Gateway: POST /checkout<br/>JWT + Idempotency-Key
    Gateway->>Order: POST /checkout<br/>X-User-ID

    Order->>OrderDB: FindOrCreate CheckoutGroup<br/>(buyer_id + idempotency_key)

    Order->>Cart: GET /cart
    Cart->>CartDB: Read buyer cart
    Cart-->>Order: Cart items

    Order->>Catalog: Validate product availability
    Catalog->>CatalogDB: Read products / stock
    Catalog-->>Order: Availability OK

    Order->>OrderDB: Create one Order per seller<br/>status = pendiente de pago

    Order->>Catalog: POST /internal/stock/reservations
    Catalog->>CatalogDB: SELECT FOR UPDATE products
    Catalog->>CatalogDB: Deduct stock + create reservation<br/>status = reserved
    Catalog-->>Order: Reservation reserved

    Order->>OrderDB: Update stock_reservation_status = reserved

    Order->>Payment: POST /internal/payments<br/>Idempotency-Key: payment-{checkout_group_id}
    Payment->>PaymentDB: Create or return existing payment
    Payment-->>Order: Payment status = approved

    Order->>OrderDB: Save payment_id<br/>payment_status = approved<br/>checkout_group.status = payment_approved

    Order->>Catalog: POST /internal/stock/reservations/{checkoutGroupId}/confirm
    Catalog->>CatalogDB: Mark reservation confirmed<br/>does not deduct stock again
    Catalog-->>Order: Reservation confirmed

    Order->>OrderDB: Mark all orders as confirmada
    Order->>OrderDB: stock_confirmation_status = confirmed<br/>orders_confirmation_status = confirmed<br/>checkout_group.status = confirmed

    Order->>Cart: POST /internal/checkout-cleanup
    Cart->>CartDB: Remove purchased quantities<br/>idempotent by checkout_group_id
    Cart-->>Order: Cleanup OK

    Order->>OrderDB: cart_cleanup_status = cleared

    Order-->>Gateway: 201 CheckoutResponse<br/>status = confirmed
    Gateway-->>Buyer: Purchase confirmed

    Note over Catalog,CatalogDB: Stock was already deducted during reservation.
    Note over Order,Cart: Cart cleanup happens only after approved payment and confirmed orders.
```

### 7. Pago rechazado (estado `payment_rejected`)

El flujo ocurre cuando `payment-service` responde `201` con `status: "rejected"`. El pago falló en el provider externo.

- el stock estaba reservado pero se libera;
- las órdenes quedan en `pago rechazado`;
- el carrito NO se limpia;
- `order-service` responde `201 { status: payment_rejected }`.

```mermaid
sequenceDiagram
    autonumber
    actor Buyer as Buyer / Mobile
    participant Gateway as API Gateway
    participant Order as order-service
    participant OrderDB as Order DB
    participant Cart as cart-service
    participant CartDB as Cart DB
    participant Catalog as catalog-service
    participant CatalogDB as Catalog DB
    participant Payment as payment-service
    participant PaymentDB as Payment DB

    Buyer->>Gateway: POST /checkout<br/>JWT + Idempotency-Key
    Gateway->>Order: POST /checkout<br/>X-User-ID

    Order->>OrderDB: FindOrCreate CheckoutGroup<br/>(buyer_id + idempotency_key)

    Order->>Cart: GET /cart
    Cart->>CartDB: Read buyer cart
    Cart-->>Order: Cart items

    Order->>Catalog: Validate product availability
    Catalog->>CatalogDB: Read products / stock
    Catalog-->>Order: Availability OK

    Order->>OrderDB: Create one Order per seller<br/>status = pendiente de pago

    Order->>Catalog: POST /internal/stock/reservations
    Catalog->>CatalogDB: SELECT FOR UPDATE products
    Catalog->>CatalogDB: Deduct stock + create reservation<br/>status = reserved
    Catalog-->>Order: Reservation reserved

    Order->>OrderDB: Update stock_reservation_status = reserved

    Order->>Payment: POST /internal/payments<br/>Idempotency-Key: payment-{checkout_group_id}
    Payment->>PaymentDB: Create or return existing payment
    Payment-->>Order: Payment status = rejected

    Order->>OrderDB: Save payment_id<br/>payment_status = rejected<br/>checkout_group.status = payment_rejected

    Order->>Catalog: POST /internal/stock/reservations/{checkoutGroupId}/release
    Catalog->>CatalogDB: SELECT FOR UPDATE reserved products
    Catalog->>CatalogDB: Restore reserved stock<br/>reservation.status = released
    Catalog-->>Order: Reservation released

    Order->>OrderDB: Mark all orders as pago rechazado
    Order->>OrderDB: stock_reservation_status = released<br/>checkout_group.status = payment_rejected

    Order-->>Gateway: 201 CheckoutResponse<br/>status = payment_rejected
    Gateway-->>Buyer: Payment rejected

    Note over Order,Cart: Cart is not cleaned.
    Note over Catalog,CatalogDB: Stock is restored because payment failed.
```

## Matriz Contra Enunciado Del TP

| Criterio del enunciado | Cómo se resuelve | Endpoint/servicio | Estado | Observaciones |
|---|---|---|---|---|
| checkout exitoso | Saga orquestada: carrito -> reserva -> pago -> confirmación -> cleanup | `POST /checkout`, `order-service`, `catalog-service`, `payment-service`, `cart-service` | Implementado | respuesta `201`; una compra visible, N órdenes por seller |
| pago rechazado | rechazo en body del payment + release de stock + órdenes `pago rechazado` | `POST /internal/payments`, `POST /internal/stock/reservations/{id}/release` | Implementado | no usa `HTTP 402` |
| stock insuficiente | reserva transaccional all-or-nothing corta el flujo antes del pago | `POST /internal/stock/reservations` | Implementado | `409`; carrito intacto; payment no se llama |
| carrera por último ítem | lock pesimista con `SELECT FOR UPDATE` y orden estable por `product_id` | `catalog-service` | Implementado | evita doble venta |
| idempotencia | unique `(buyer_id, idempotency_key)`, unique `checkout_group_id`, unique cleanup op | `order-service`, `payment-service`, `catalog-service`, `cart-service` | Implementado | replay de `POST /checkout` sigue devolviendo `201` |
| dirección obligatoria | binding requerido sobre `delivery_address` | `CheckoutRequest` en `order-service` | Implementado | `delivery_city` y `delivery_province` son opcionales |
| multi-vendedor | un `checkout_group_id`, una orden por `seller_id`, un pago único | `order-service` | Implementado | decisión base de ADR 0008 |
| visibilidad seller/admin/buyer | buyer ve su compra; seller ve solo sus órdenes; admin ve lectura global | gateway + `order-service` | Implementado | `GET /checkout-groups/:id` es buyer/admin; seller no accede |

## Estado Real Vs Pendiente

| Tema | Estado | Detalle verificado |
|---|---|---|
| `POST /checkout` | Implementado; documentación corregida | controller real devuelve `201 Created`, no `200` |
| `POST /checkout/quote` | Implementado parcialmente | funciona y es read-only; `coupon_code` todavía se rechaza |
| stock `reserve/confirm/release` | Implementado; documentación corregida | `reserve` descuenta; `confirm` no descuenta; `release` solo restaura si estaba `reserved` |
| cleanup de carrito | Implementado; documentación corregida | endpoint real `POST /internal/checkout-cleanup`; body `buyer_id`, `checkout_group_id`, `items[]`; idempotencia por tabla `cart_cleanup_operations` |
| payment rejected | Implementado; documentación corregida | rechazo va en body `status: rejected` con `201`; no `HTTP 402` |
| estados reales de pago | Implementado | `pending`, `approved`, `rejected`, `refund_pending`, `refunded`, `refund_failed`, `preference_failed` |
| refund técnico en payment-service | Implementado | `RefundPayment` puede completar `approved -> refund_pending -> refunded` y notifica a `order-service` por callback |
| refund automático desde order-service | Parcial / pendiente | la arquitectura lo contempla, pero `order-service` no tiene hoy una integración runtime cableada para dispararlo automáticamente en checkout/cancelación |
| buyer `GET /orders?status=` | Implementado; documentación corregida | el filtro por estado sí existe en controller y repository |
| mobile checkout E2E | Pendiente | el tab `cart` es placeholder y no ejecuta checkout real |
| backoffice órdenes E2E | Pendiente | `adminService.ts` mantiene órdenes/métricas sobre mocks |
| OpenAPI manual del order-service | Documentación corregida | request names, códigos HTTP, cleanup, quote y contratos internos alineados con la implementación real |

## Rutas Verificadas En Gateway

`Bazaar-backend-api-gateway` enruta estas superficies a `order-service`:

- `/checkout`
- `/checkout-groups/`
- `/orders/`
- `/seller/orders/`
- `/admin/orders/`

Esto coincide con `internal/config/config.go` del gateway. Las rutas `/internal/*` no pasan por el gateway.

## Decisiones Defendibles Para El TP

- La compra visible del comprador y las órdenes operativas por vendedor están separadas.
- La consistencia distribuida se resuelve con Saga orquestada, no con 2PC.
- La concurrencia crítica del último ítem se resuelve en el servicio dueño del stock.
- La idempotencia está resuelta por claves de negocio y constraints persistentes, no solo por convención de frontend.
- El estado E2E real hoy es principalmente backend; frontend mobile y backoffice todavía tienen partes mockeadas o no integradas.

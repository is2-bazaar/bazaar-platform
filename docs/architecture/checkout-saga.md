# Checkout Saga

## Resumen

El checkout distribuido de Bazaar resuelve el desafío de procesar una intención de compra multi-vendedor a través de varios microservicios de manera consistente y segura. Para el comprador, la operación se percibe como una única compra consolidada y un único pago. Internamente, el sistema gestiona la concurrencia de stock, la separación de órdenes por vendedor y la idempotencia ante reintentos.

El flujo se implementa como una **Saga orquestada**, donde `order-service` actúa como el coordinador central que invoca a otros servicios de dominio (catalog, payment, cart) y maneja las compensaciones si algún paso falla, garantizando consistencia eventual ante caídas parciales de la red o servicios.

## Objetivos del diseño

El diseño del flujo de checkout busca garantizar los siguientes atributos de calidad y reglas de negocio:

- **No doble cobro**: los pagos son estrictamente idempotentes usando una clave determinista `payment-{checkout_group_id}`. La BD de payment-service impone un unique index sobre `checkout_group_id`.
- **No doble descuento de stock**: la reserva en catalog-service usa `SELECT FOR UPDATE` en transacción y es idempotente por `checkout_group_id`. La confirmación nunca descuenta de nuevo; solo marca la reserva existente como permanente.
- **No venta doble del último ítem**: locking a nivel de fila (`SELECT FOR UPDATE`) con ordenamiento de `product_id` ascendente en catalog-service previene deadlocks y garantiza que dos compradores concurrentes no se lleven el mismo stock.
- **Soporte multi-vendedor**: un único carrito puede derivar en múltiples órdenes operativas separadas (una por seller), manteniendo la integridad visual de un solo intento de compra para el comprador.
- **Reintentos seguros**: el frontend puede reintentar la llamada al checkout con la misma `Idempotency-Key` sin duplicar side-effects. La dupla `(buyer_id, idempotency_key)` es unique index en `checkout_groups`.
- **Recuperación ante timeout**: se proveen endpoints de reconciliación (`GET /checkout/attempts/:key`, `GET /checkout-groups/:id`) para que el cliente pueda consultar el estado de un intento sin disparar efectos secundarios.
- **Carrito no borrado incorrectamente**: la limpieza del carrito no es un "clear all", sino que descuenta específicamente las cantidades compradas. La tabla `cart_cleanup_operations` con unique index sobre `checkout_group_id` previene limpiezas duplicadas ante retries tardíos.
- **Separación de responsabilidades por servicio**: catalog maneja inventario, payment la pasarela, cart los ítems temporales y order orquesta el ciclo de vida del checkout.

## Servicios involucrados

| Servicio | Responsabilidad | Endpoints Relevantes | Persistencia propia | Comunicación |
|----------|-----------------|----------------------|---------------------|--------------|
| **API Gateway** | Punto de entrada, ruteo, validación JWT, CORS, rate limiting | `POST /checkout`, `GET /checkout/attempts/:key`, `GET /checkout-groups/:id`, `GET /orders`, `GET /seller/orders`, `GET /admin/orders` | No | HTTP/JSON síncrono |
| **order-service** | Orquestador de la Saga, gestión de órdenes y checkout groups | `POST /checkout`, `GET /checkout/attempts/:idempotencyKey`, `GET /checkout-groups/:checkoutGroupId`, `GET /orders`, `POST /orders/:orderId/cancel`, `POST /orders/:orderId/confirm-delivery`, `GET /seller/orders`, `POST /seller/orders/:orderId/status`, `GET /admin/orders` | PostgreSQL (checkout_groups, orders, order_items, order_status_histories) | Públicas: JWT via Gateway. `/internal`: JWT admin (Bearer). Hacia otros servicios: `X-Internal-Service-Token` |
| **catalog-service** | Manejo de stock y validación de productos | `POST /internal/stock/reservations`, `POST /internal/stock/reservations/:checkoutGroupId/confirm`, `POST /internal/stock/reservations/:checkoutGroupId/release` | PostgreSQL (products, stock_reservations, stock_reservation_items) | HTTP/JSON interna, `X-Internal-Service-Token` |
| **payment-service** | Pasarela de pagos idempotente con modo simulado | `POST /internal/payments`, `POST /internal/payments/:paymentId/refund` | PostgreSQL (payments) | HTTP/JSON interna, `X-Internal-Service-Token` |
| **cart-service** | Gestión del carrito y limpieza selectiva post-checkout | `POST /internal/checkout-cleanup` | PostgreSQL (carts, cart_items, cart_cleanup_operations) | HTTP/JSON interna, `X-Internal-Service-Token` |
| **auth-service** | Emisión y validación de credenciales JWT | No participa directamente en el flujo de checkout | PostgreSQL (accounts, tokens) | Validación de JWT delegada al API Gateway |

**Nota**: auth-service no recibe llamadas durante el flujo de checkout. La validación de JWT la realiza el API Gateway, que inyecta headers `X-User-ID`, `X-User-Role` y `X-User-Email` hacia los servicios downstream. Las rutas `/internal/*` NO están expuestas a través del API Gateway — son comunicación service-to-service directa.

## Modelo conceptual

- **CheckoutGroup**: Agregado raíz del intento de compra. Identificado por `checkout_group_id`. Agrupa N órdenes hijas y mantiene el estado de progreso de la saga (stock reservation, payment, stock confirmation, orders confirmation, cart cleanup). La dupla `(buyer_id, idempotency_key)` tiene unique index.
- **Order**: Orden de compra generada para un único vendedor (`seller_id`). La dupla `(checkout_group_id, seller_id)` tiene unique index, garantizando exactamente una orden por vendedor dentro de un grupo.
- **CheckoutGroupStatus**: Máquina de estados de 12 estados que refleja tanto el progreso de la saga como el fulfillment post-compra.
- **OrderItem**: Ítem comprado dentro de una orden, contiene snapshot del nombre, precio e imagen del producto al momento de la compra.
- **StockReservation**: Registro temporal de stock retenido durante el intento de pago. Estados: `reserved → confirmed | released`. El stock se descuenta en `reserve`, NO en `confirm`. La `confirmación` solo marca la reserva como permanente.
- **Payment**: Transacción económica. Estados: `pending → approved | rejected`. `approved → refund_pending → refunded`. Unique index sobre `checkout_group_id` y sobre `idempotency_key`. El provider es `"simulated"` — no hay integración real con MercadoPago.
- **CartCleanupOperation**: Registro de limpieza idempotente. Unique index sobre `checkout_group_id`. La primera inserción gana; reintentos ven `RowsAffected == 0` y retornan sin tocar items.

```
CheckoutGroup G1 (idempotency_key: "abc-123")
├── Order O1 — seller A
├── Order O2 — seller B
└── Order O3 — seller C
```

## Idempotencia

El sistema soporta reintentos seguros en todos sus niveles usando un esquema de derivación de claves de idempotencia determinista:

- **Request público**: `buyer_id` + `Idempotency-Key` (del header HTTP) → `checkout_group_id`. Unique index en BD. La clave la genera el frontend (UUID), no es un secreto y está scopeada por comprador. Retries de una misma compra deben enviar la misma key. Nuevas compras deben usar una key nueva.
- **Órdenes**: Unique index sobre `(checkout_group_id, seller_id)` garantiza exactamente una orden por vendedor dentro del grupo.
- **Stock reserva**: Idempotente por `checkout_group_id` (unique index en `stock_reservations`). Estados `reserved` o `confirmed` → retorna existente sin volver a descontar. Estado `released` → 409.
- **Stock confirmación**: Idempotente. Si ya `confirmed` → éxito sin tocar stock. Si `released` → 409.
- **Stock liberación**: Idempotente. Si ya `released` → éxito sin restaurar stock de nuevo. Si `confirmed` → 409 (no se puede liberar stock ya confirmado).
- **Payment**: Unique index sobre `checkout_group_id` y sobre `idempotency_key`. El idempotency key se deriva como `payment-{checkout_group_id}` si no se provee explícitamente. Si ya existe un pago para ese grupo, retorna el existente (sin re-evaluar el estado).
- **Payment refund**: Idempotente. Si ya está en `refund_pending` o `refunded` → retorna éxito sin re-ejecutar.
- **Cart cleanup**: Idempotente vía `cart_cleanup_operations` con unique index sobre `checkout_group_id`. Primera inserción gana (`ON CONFLICT DO NOTHING`). `RowsAffected == 0` → skip total de la limpieza.

## Flujo feliz

1. **Buyer** llama a `POST /checkout` pasando JWT (validado por API Gateway) y header `Idempotency-Key`.
2. **order-service** ejecuta `FindOrCreateCheckoutGroup` — UPSERT con `ON CONFLICT DO NOTHING` sobre `(buyer_id, idempotency_key)`. Si ya existe, recupera el grupo y evalúa su estado (auto-healing de `GrandTotal=0`, reanudación de saga).
3. **order-service** obtiene el carrito llamando a cart-service (`GET /cart`).
4. **order-service** ejecuta `validateAvailability` — llama concurrentemente a catalog-service por cada producto para verificar que esté activo y tenga stock. Esta validación es preliminar; la protección real de concurrencia está en el paso de reserva.
5. **order-service** agrupa items por `seller_id`, crea una `Order` por vendedor dentro de una transacción local, persiste el `CheckoutGroup` con `grand_total` y estado `pending_payment`.
6. **order-service** llama a catalog-service: `POST /internal/stock/reservations`. Envía todos los items agrupados por `product_id` (cantidades sumadas si hay duplicados).
7. **catalog-service** ejecuta en transacción: (a) lockea fila de reserva existente si la hay, (b) ordena `product_ids` ascendentemente, (c) lockea cada producto con `SELECT FOR UPDATE`, (d) valida stock suficiente para todos, (e) descuenta stock, (f) crea `StockReservation` con items. Todo es all-or-nothing: si un producto falla, la transacción completa hace rollback.
8. **order-service** llama a payment-service: `POST /internal/payments` con `amount=grand_total`, `checkout_group_id`, `idempotency_key=payment-{checkout_group_id}`.
9. **payment-service** verifica idempotencia (unique index), crea payment con estado según `PAYMENT_SIMULATION_MODE` (default: `approved`) o header `X-Payment-Simulation-Status`.
10. **order-service** evalúa el resultado del pago:
    - **approved** → `handleApprovedPaymentConfirm`: (a) `POST .../confirm` a catalog, (b) bulk-update de órdenes a `confirmada`, (c) actualiza CG a `confirmed`.
    - **rejected** → `handleRejectedPaymentRelease`: (a) persiste CG como `compensating`, (b) `POST .../release` a catalog, (c) bulk-update de órdenes a `pago rechazado`, (d) actualiza CG a `payment_rejected`.
11. **order-service** ejecuta `cleanupCartAfterConfirmedPurchase`: llama a cart-service `POST /internal/checkout-cleanup` con `buyer_id`, `checkout_group_id` e `items[]`. Esta llamada es idempotente y no revierte la compra si falla (solo loguea el error).
12. **order-service** responde al frontend con `CheckoutResponse` incluyendo `checkout_group_id`, `grand_total`, `orders[]`, `payment_url` (si pending).

```
Buyer
 → API Gateway (valida JWT, inyecta X-User-ID)
 → order-service
   ├── GET cart-service (fetch cart)
   ├── POST catalog-service /internal/stock/reservations (reserve stock)
   ├── POST payment-service /internal/payments (create payment)
   ├── POST catalog-service .../confirm (confirm stock)        ← solo si approved
   ├── POST cart-service /internal/checkout-cleanup (cleanup)  ← solo si approved + confirmed
   └── responde 201 Created
```

## Orden real de efectos externos

El orden estricto garantiza que no haya cobros sin productos disponibles:

1. **`validateAvailability`** es preliminar y no bloqueante. No modifica stock.
2. **`reserveStock`** en catalog-service es la protección real de concurrencia. Bloquea filas con `SELECT FOR UPDATE`, descuenta stock y crea la reserva en una transacción atómica.
3. **`createPayment`** ocurre **después** de reservar stock. Si el pago es rechazado, se libera la reserva.
4. **`confirmStock`** no descuenta stock nuevamente; solo marca la reserva como permanente (transición `reserved → confirmed`).
5. **`cleanupCart`** ocurre al final, después de que stock y órdenes están confirmados. Si falla, no se revierte la compra — se loguea el error y el frontend puede reintentar vía reconciliación.

**"Primero reservamos stock, después cobramos. Después del pago aprobado no reservamos: confirmamos la reserva ya existente."**

## Escenarios de error

| Escenario | Qué pasa | Stock | Pago | Órdenes | Carrito | CG Status |
|-----------|----------|-------|------|---------|---------|-----------|
| **Carrito vacío** | order-service retorna `ErrCartEmpty` | Intacto | No llamado | No creadas | Intacto | No creado |
| **Dirección inválida** | Validación falla temprano en el handler | Intacto | No llamado | No creadas | Intacto | No creado |
| **Producto inexistente/deshabilitado** | `validateAvailability` falla; no se crean órdenes | Intacto | No llamado | No creadas | Intacto | No creado o `pending_stock` |
| **Stock insuficiente (reserve)** | catalog retorna 409 `StockInsufficientError` | Intacto (rollback) | No llamado | Creadas pero sin confirmar | Intacto | `pending_payment` con error |
| **Carrera por último ítem** | `SELECT FOR UPDATE` + ordenamiento por product_id. Ganador descuenta stock, perdedor recibe 409 | Ganador: reservado. Perdedor: intacto | Solo el ganador | Perdedor falla antes de payment | Intacto | Ganador: avanza. Perdedor: falla |
| **Pago rechazado** | payment-service crea payment con `status: "rejected"` (HTTP 201). order-service ejecuta `handleRejectedPaymentRelease`: libera stock, marca órdenes `pago rechazado` | Liberado (`released`) | Rejected | `pago rechazado` | Intacto (no se limpió) | `payment_rejected` |
| **Pago pending** | payment-service crea payment con `status: "pending"` y genera `payment_url`. order-service retorna respuesta con URL | Reservado (`reserved`) | Pending | `pendiente de pago` | Intacto | `pending_payment` |
| **Timeout de payment** | order-service no sabe si el pago se procesó. El estado queda `pending_payment` con stock reservado | Reservado | Desconocido | `pendiente de pago` | Intacto | `pending_payment` |
| **Timeout de catalog reserve** | order-service no sabe si catalog reservó. Retry de checkout reintentará la reserva; catalog es idempotente | Posible reserva huérfana | No llamado | `pendiente de pago` | Intacto | `pending_payment` |
| **Timeout de catalog confirm** | Pago fue aprobado, pero `confirmStock` falló/timeout. Stock queda `reserved`, órdenes **NO** pasan a `confirmada`. CG queda en `payment_approved` con `stock_confirmation_status` sin confirmar | `reserved` (no liberado) | Approved | `pendiente de pago` (no confirmadas aún) | Intacto | `payment_approved` (reintentable/compensable) |
| **Falla de cleanup** | `POST /internal/checkout-cleanup` falla (timeout/500). order-service loguea el error pero NO revierte. Stock y órdenes ya están confirmados | Confirmado | Approved | `confirmada` | Sucio (ítems comprados siguen en carrito) | `confirmed` con `cart_cleanup_status: "failed"` |
| **Retry de POST /checkout** | Hit por `Idempotency-Key`. order-service recupera CG existente y reanuda o retorna estado actual | Ya consolidado | Ya procesado | Estado actual | Estado actual | Retorna 200 con estado actual |
| **Retry tardío de cleanup** | cart-service ve `cart_cleanup_operations` con ese `checkout_group_id`, `RowsAffected == 0`, retorna sin tocar items | No afecta | No afecta | No afecta | Ítems agregados post-compra sobreviven | No afecta |
| **Respuesta perdida al frontend** | Red cae después de que order-service completó todo. Frontend usa `GET /checkout/attempts/:key` para recuperar estado | Confirmado | Approved | `confirmada` | Limpio | `confirmed` |

## Race condition del último ítem

Escenario: producto con `stock_quantity = 1`, dos compradores (A y B) inician checkout simultáneamente.

1. `order-service` de A y B llaman a `POST /internal/stock/reservations` concurrentemente.
2. `catalog-service` ejecuta `BatchReserveProducts` en transacción:
   - Ordena `product_ids` ascendentemente (`sort.Ints`) para prevenir deadlocks.
   - Lockea cada producto con `SELECT FOR UPDATE` en orden.
3. A obtiene el lock primero. Descuenta stock de 1 a 0. Crea `StockReservation` con status `reserved`. Commit exitoso.
4. B queda bloqueado esperando el lock. Cuando lo obtiene, ve `stock_quantity = 0`. Valida que `requested > available`. Retorna 409 `StockInsufficientError`. Rollback total.
5. A procede a payment. B recibe error y no llega a tocar payment-service.

**Garantías**: El lock de fila + transacción asegura atomicidad. El ordenamiento de product_ids previene deadlocks circulares. La reserva es all-or-nothing: si un solo producto del batch falla, ningún stock se descuenta.

## Cleanup seguro de carrito

Implementado en `cart-service/internal/repository/cart_cleanup_repository.go`. El mecanismo:

1. `order-service` envía `POST /internal/checkout-cleanup` con `buyer_id`, `checkout_group_id` e `items[]` (product_id + quantity comprada).
2. `cart-service` ejecuta en **transacción**:
   - **Idempotency guard**: `INSERT INTO cart_cleanup_operations (checkout_group_id) ON CONFLICT DO NOTHING`. Si `RowsAffected == 0`, retorna inmediatamente (ya fue procesado).
   - **Lock de items**: `SELECT ... FOR UPDATE` sobre los `cart_items` del comprador que matchean los `product_id` enviados.
   - **Hard delete o decremento**: si `cart_item.quantity <= purchased_quantity`, se elimina el item (hard delete con `Unscoped()`). Si `cart_item.quantity > purchased_quantity`, se decrementa la cantidad.
   - **Commit**: todo ocurre atómicamente.

**Ejemplo de escenario concurrente**:
1. Carrito tiene producto X con cantidad 2.
2. Checkout compra X con cantidad 2.
3. Durante el pago, el usuario agrega X con cantidad 3 en otra pestaña. Total carrito: 5.
4. Cleanup descuenta exactamente 2 (las compradas). Resultado: X queda con cantidad 3.
5. Un retry tardío del cleanup ve `RowsAffected == 0` en `cart_cleanup_operations` y no toca nada. Las 3 unidades agregadas post-compra sobreviven.

## Reconciliación frontend

Si el cliente pierde conexión (timeout del API Gateway, app se cierra, pantalla de pago pending), dispone de dos endpoints de solo lectura:

- **`GET /checkout/attempts/:idempotencyKey`**: Busca el `CheckoutGroup` por `(buyer_id, idempotency_key)`. No dispara side effects. Retorna el estado actual del grupo y sus órdenes hijas. Útil cuando el frontend conservó la key pero no recibió respuesta.
- **`GET /checkout-groups/:checkoutGroupId`**: Busca por `checkout_group_id`. Ownership restringido: solo el buyer dueño o admin pueden acceder. Retorna detalle con campos de progreso de saga (`payment_status`, `stock_reservation_status`, `stock_confirmation_status`, `orders_confirmation_status`) y las órdenes hijas. Útil cuando el frontend llegó a recibir el `checkout_group_id` pero perdió la respuesta completa.

Ambos endpoints aplican privacy hardening de SDD9: un buyer ajeno recibe 404. Campos internos (`idempotency_key`, `last_error`, `cart_cleanup_status`, `stock_reservation_id`, tokens internos) NO se exponen en el DTO público bajo ningún rol — ni para el dueño ni para admin. El contrato público de `CheckoutGroupResponse` incluye únicamente: `id`, `buyer_id`, `status`, `grand_total`, `payment_status`, `stock_reservation_status`, `stock_confirmation_status`, `orders_confirmation_status`, `orders[]`, `message` (opcional).

## Estados de entidades

### CheckoutGroup — máquina de estados de la saga (12 estados)

El `CheckoutGroup` persiste tanto el estado agregado del intento de compra como el progreso granular de cada paso de la saga. Esto permite reintentos y diagnóstico ante fallos parciales.

```
pending_stock → pending_payment → payment_approved → confirmed → preparing → shipped → delivered
                  ↓                    ↓                                          
            payment_rejected     compensating → failed                           
                                                  ↓
                                               cancelled
completed (terminal)
```

**Campos de progreso de saga** (independientes del status agregado):

| Campo | Valores posibles | Propósito |
|-------|-----------------|-----------|
| `PaymentStatus` | `nil`, `"approved"`, `"rejected"` | Resultado del pago |
| `StockReservationStatus` | `nil`, `"pending"`, `"reserved"`, `"released"`, `"failed"` | Estado de la reserva en catalog |
| `StockConfirmationStatus` | `nil`, `"confirmed"` | Si catalog marcó la reserva como permanente |
| `OrdersConfirmationStatus` | `nil`, `"confirmed"` | Si las órdenes hijas fueron confirmadas |
| `CartCleanupStatus` | `nil`, `"cleared"`, `"failed"` | Resultado del cleanup en cart |
| `LastError` | `nil` o string | Último error de la saga para diagnóstico |

### Order — máquina de estados (9 estados)

```
pendiente de pago → confirmada → en preparación → enviada → entregada
       ↓                ↓              ↓
pago rechazado      cancelada      cancelada
                       ↓
               reembolso en proceso → reembolso procesado
```

**Nota**: Los estados posteriores a `confirmada` (`en preparación`, `enviada`, `entregada`) se alcanzan mediante endpoints de vendedor/comprador, NO durante el checkout. El checkout deja las órdenes en `confirmada`.

**Transiciones válidas** (enforced en `UpdateOrderStatus`):

| Desde | Hacia |
|-------|-------|
| `pendiente de pago` | `confirmada`, `pago rechazado`, `cancelada` |
| `confirmada` | `en preparación`, `cancelada` |
| `en preparación` | `enviada`, `cancelada` |
| `enviada` | `entregada` |
| `cancelada` | `reembolso en proceso` |
| `reembolso en proceso` | `reembolso procesado` |

### Payment — estados

```
pending → approved → refund_pending → refunded
        ↘ rejected (terminal)
```

**Nota sobre refund**: El endpoint `POST /internal/payments/:paymentId/refund` existe y permite iniciar una compensación técnica o un futuro flujo de cancelación. Hoy transiciona a `refund_pending`. La transición a `refunded` no está implementada (no hay webhook ni job asíncrono que complete el refund), por lo que la historia completa de reembolso simulado y cancelación con refund sigue parcial.

### StockReservation — estados

```
reserved → confirmed (terminal, no reversible)
         → released  (terminal, no reversible)
```

**Nota**: No existe estado `pending` en el modelo real. La reserva se crea directamente como `reserved` (el stock ya fue descontado). `confirmed` y `released` son estados terminales; no se puede transicionar entre ellos ni revertirlos.

## Privacidad y SDD9

Implementado en `order-service/internal/service/order_service.go` y `order-service/internal/transport/http/router/routes.go`:

- **Buyer**: `GetOrderForUser` verifica `order.BuyerID == userID`. Si no matchea, retorna `ErrNotFound` (404). El buyer nunca ve órdenes de otros compradores.
- **Seller**: `GetOrderForSeller` verifica `order.SellerID == userID` a nivel raíz. Las rutas de seller (`/seller/orders`, `/seller/orders/:id`, `/seller/orders/:id/status`) usan middleware `RequireRole("user")` que **excluye** al admin — un admin no puede acceder a rutas de seller. Si un seller intenta acceder a una orden que no le pertenece, recibe 404.
- **Seller no ve órdenes hermanas**: `GetCheckoutGroup` está restringido a buyer (dueño) o admin. Un seller no puede consultar el `CheckoutGroup` y por tanto no puede enumerar órdenes de otros vendedores dentro del mismo grupo.
- **Admin**: Rutas separadas bajo `/admin/orders` con middleware `RequireRole("admin")`. El admin tiene acceso de solo lectura a todas las órdenes y checkout groups. No puede mutar estados de órdenes (no tiene acceso a `POST /seller/orders/:id/status`).
- **Recursos ajenos ocultos como 404**: Los errores de autorización se mapean a `404 Not Found` en lugar de `403 Forbidden` para evitar enumeración de recursos.
- **Regla general 403 vs 404**:
  - **Rol incorrecto / middleware bloquea** (ej: admin accediendo a `/seller/orders`, buyer accediendo a `/admin/orders`) → **403 Forbidden**. El middleware de rol rechaza antes de llegar al handler.
  - **Rol válido pero recurso ajeno** (ej: seller A accediendo a orden de seller B, buyer accediendo a orden de otro buyer) → **404 Not Found**. El handler verifica ownership y oculta el recurso.
  - Esta distinción es deliberada: 403 = "no tenés permiso para usar este endpoint", 404 = "ese recurso no existe o no es tuyo".

## Endpoints públicos

Ruteados a través del API Gateway (`Bazaar-backend-api-gateway`). El gateway valida JWT, inyecta headers `X-User-ID`, `X-User-Role`, `X-User-Email` y forwardea al order-service.

| Método | Path | Actor | Propósito | Estado |
|--------|------|-------|-----------|--------|
| `POST` | `/checkout` | Buyer | Iniciar proceso de checkout | **Implementado** |
| `POST` | `/checkout/quote` | Buyer | Cotización previa de compra | **Stub (501)** |
| `GET` | `/checkout/attempts/:idempotencyKey` | Buyer | Reconciliación por idempotency key | **Implementado** |
| `GET` | `/checkout-groups/:checkoutGroupId` | Buyer, Admin | Detalle consolidado de compra con progreso de saga | **Implementado** |
| `GET` | `/orders` | Buyer | Historial de compras del buyer autenticado | **Implementado** (paginado, sin filtro por status) |
| `GET` | `/orders/:orderId` | Buyer | Detalle de una orden con items y status history | **Implementado** |
| `POST` | `/orders/:orderId/cancel` | Buyer | Cancelar orden (`confirmada` o `en preparación`). Dispara refund si tiene payment | **Implementado** |
| `POST` | `/orders/:orderId/confirm-delivery` | Buyer | Confirmar entrega (transición a `entregada`) | **Implementado** |
| `GET` | `/seller/orders` | Seller | Historial de ventas del seller autenticado | **Implementado** (paginado, con filtro por status) |
| `GET` | `/seller/orders/:orderId` | Seller | Detalle de venta con items y dirección de entrega | **Implementado** |
| `POST` | `/seller/orders/:orderId/status` | Seller | Avanzar estado (`en preparación` → `enviada`). Acepta `tracking_code` | **Implementado** |
| `GET` | `/seller/coupons` | Seller | Listar cupones del seller | **Stub (501)** |
| `POST` | `/seller/coupons` | Seller | Crear cupón | **Stub (501)** |
| `PATCH` | `/seller/coupons/:couponId` | Seller | Editar cupón | **Stub (501)** |
| `POST` | `/seller/coupons/:couponId/deactivate` | Seller | Desactivar cupón | **Stub (501)** |
| `GET` | `/admin/orders` | Admin | Listado de todas las órdenes del sistema | **Implementado** (paginado, con filtro por status) |
| `GET` | `/admin/orders/:orderId` | Admin | Detalle de orden (read-only) | **Implementado** |

## Endpoints internos

Protegidos por `X-Internal-Service-Token`. NO expuestos a través del API Gateway. Comunicación service-to-service directa.

| Método/Path | Llamador | Idempotency Key | Efecto | Estado |
|-------------|----------|-----------------|--------|--------|
| `POST /internal/stock/reservations` | order-service | `{checkout_group_id}` (unique index en BD) | Reserva stock en transacción con `SELECT FOR UPDATE`, all-or-nothing | **Implementado** |
| `POST /internal/stock/reservations/:checkoutGroupId/confirm` | order-service | `{checkout_group_id}` (idempotente por estado) | Marca reserva como permanente (`reserved → confirmed`) | **Implementado** |
| `POST /internal/stock/reservations/:checkoutGroupId/release` | order-service | `{checkout_group_id}` (idempotente por estado) | Restaura stock y marca reserva como liberada (`reserved → released`) | **Implementado** |
| `POST /internal/payments` | order-service | `payment-{checkout_group_id}` (unique index en BD) | Crea payment. Simulación: `approved`/`rejected`/`pending` según `PAYMENT_SIMULATION_MODE` o header `X-Payment-Simulation-Status` | **Implementado** |
| `POST /internal/payments/:paymentId/refund` | order-service | Idempotente por estado (`refund_pending`/`refunded`) | Transiciona a `refund_pending`. No llega a `refunded` (sin webhook asíncrono) | **Implementado** (parcial: falta transición `refund_pending → refunded`) |
| `POST /internal/checkout-cleanup` | order-service | `{checkout_group_id}` (unique index en `cart_cleanup_operations`) | Limpia cantidades compradas del carrito. Hard delete o decremento. `SELECT FOR UPDATE` sobre cart items | **Implementado** |
| `POST /internal/orders` | (interno, no usado por la saga) | — | Crear orden interna | **Stub (501)** |
| `POST /internal/orders/:orderId/mark-payment-approved` | (callback externo, no usado) | — | Marcar orden con pago aprobado | **Stub (501)** |
| `POST /internal/orders/:orderId/mark-payment-rejected` | (callback externo, no usado) | — | Marcar orden con pago rechazado | **Implementado** |
| `POST /internal/orders/:orderId/mark-refund-processed` | (callback externo, no usado) | — | Marcar orden con refund procesado | **Stub (501)** |

**Nota sobre stubs**: Los endpoints marcados como stub (501) existen como placeholders pero no se usan en el flujo actual de la saga. El flujo real de checkout usa llamadas directas de order-service a catalog/payment/cart, no callbacks inversos.

## Relación con el enunciado

| Historia / Criterio del enunciado | Cómo se cubre | Estado | Evidencia en código |
|-----------------------------------|---------------|--------|---------------------|
| Checkout exitoso | Saga orquestada completa: reserve → pay → confirm → cleanup | **Implementado** | `order_service.go:InitiateCheckout` |
| Pago rechazado | `handleRejectedPaymentRelease`: libera stock, marca órdenes `pago rechazado` | **Implementado** | `order_service.go:handleRejectedPaymentRelease` |
| Pago pending (demorado) | Payment con `status: "pending"` y `payment_url`. Frontend recibe URL para completar pago | **Implementado** | `payment_service.go:CreatePayment` (modo `pending`) |
| Stock insuficiente al checkout | catalog retorna 409, order-service no avanza a payment | **Implementado** | `stock_reservation_repository.go:BatchReserveProducts` |
| Concurrencia último ítem | `SELECT FOR UPDATE` + `sort.Ints(productIDs)` + transacción all-or-nothing | **Implementado** | `stock_reservation_repository.go` líneas 76-80, 83-96 |
| Idempotencia del pago | Unique index sobre `checkout_group_id` y `idempotency_key` en payments | **Implementado** | `payment.go:CheckoutGroupID uniqueIndex`, `payment_service.go:CreatePayment` |
| Dirección requerida | Validación en `CheckoutRequest`: `delivery_address` required | **Implementado** | `requests.go:CheckoutRequest` |
| Dirección registrada en orden | Persistida en `Order.DeliveryAddress`, `Order.DeliveryCity`, `Order.DeliveryProvince` | **Implementado** | `order.go` fields |
| Estado y seguimiento (tracking) | `tracking_code` en Order, seteado en transición a `enviada` vía `POST /seller/orders/:id/status` | **Implementado** | `order_repository.go:UpdateOrderStatus` |
| Historial de compras (buyer) | `GET /orders` paginado por `buyer_id`, ordenado por `created_at DESC` | **Implementado** | `order_repository.go:GetOrdersByBuyer` |
| Historial de compras — filtro por status | No implementado en `GET /orders` del buyer | **Parcial** | Solo paginación, sin query param `?status=` |
| Historial de ventas (seller) | `GET /seller/orders` con filtro por `seller_id` raíz y soporte de `?status=` | **Implementado** | `order_repository.go:GetOrdersBySeller` |
| Avanzar estado de orden (seller) | `POST /seller/orders/:orderId/status` con validación de transiciones | **Implementado** | `order_service.go:UpdateOrderStatus` |
| Confirmar entrega (buyer) | `POST /orders/:orderId/confirm-delivery` | **Implementado** | `order_controller.go:ConfirmDelivery` |
| Cancelar orden (buyer) | `POST /orders/:orderId/cancel` válido desde `confirmada` o `en preparación` | **Implementado** | `order_service.go:CancelOrder` |
| Cancelar orden — restaura stock | No se restaura stock automáticamente al cancelar | **Parcial** | Solo dispara refund si tiene payment; no llama a `release` de catalog |
| Reembolso (refund) | `POST /internal/payments/:paymentId/refund` transiciona a `refund_pending`. No llega a `refunded` | **Parcial** | `payment_service.go:RefundPayment` |
| Listar órdenes del sistema (admin) | `GET /admin/orders` y `GET /admin/orders/:id` | **Implementado** | `order_repository.go:GetAllOrders` |
| Admin read-only | Rutas separadas con `RequireRole("admin")`. Admin no puede acceder a rutas de seller | **Implementado** | `routes.go` líneas 60-62 (admin group), seller group excluye admin |
| Cupones — gestión (seller) | Endpoints registrados pero retornan 501 | **Stub** | `order_controller.go` handlers retornan `writeNotImplemented` |
| Cupones — aplicar en checkout | `CheckoutRequest` acepta `coupon_code` pero el servicio lo rechaza explícitamente | **Pendiente** | `order_service.go` línea: "coupons not supported for checkout groups yet" |
| Notificaciones | Ruta `/notifications/` existe en gateway pero no hay implementación | **Pendiente** | Sin código de notification-service activo |
| Consistencia distribuida | Saga orquestada con compensación (release stock si pago rechazado). No 2PC | **Implementado** | `order_service.go` saga flow completo |
| Manejo de errores distribuidos | Idempotencia en todos los niveles. Auto-healing de `GrandTotal=0`. Sin backoff/circuit breaker | **Parcial** | Idempotencia implementada; retry/backoff/circuit breaker pendientes |
| API Gateway | Punto único de entrada, ruteo, JWT, CORS, rate limiting. `/internal/*` no expuesto | **Implementado** | `gateway/config.go:defaultRoutes`, `gateway/server/docs.go:hideInternalPaths` |
| Bases separadas por servicio | Cada servicio tiene su propio PostgreSQL (`orders_db`, `cart_db`, `catalog_db`, `payment_db`, `auth_db`, `user_db`) | **Implementado** | `docker-compose.platform.yml` |

## Bugs encontrados y lecciones aprendidas

### 1. Doble limpieza de carrito en reintentos tardíos
- **Síntoma**: Un retry de `POST /internal/checkout-cleanup` que llegaba tarde (minutos/horas después) borraba productos que el usuario había vuelto a agregar al carrito.
- **Riesgo**: Pérdida de datos del carrito del usuario. Mala experiencia de compra.
- **Causa**: La primera implementación de cleanup no era idempotente; cada llamada restaba cantidades sin verificar si ya había sido procesada.
- **Fix**: Se creó la tabla `cart_cleanup_operations` con unique index sobre `checkout_group_id`. La primera inserción gana (`ON CONFLICT DO NOTHING`). Si `RowsAffected == 0`, se retorna sin tocar items. Además, el cleanup descuenta cantidades específicas (no clear-all) y usa `SELECT FOR UPDATE` sobre cart items.
- **Test**: `TestCleanupPurchasedItemsIdempotentRetry` en `cart_cleanup_repository_test.go`.
- **Estado**: Corregido.

### 2. Race condition del último ítem
- **Síntoma**: Dos compradores concurrentes podían ambos pasar la validación de stock y crear reservas para el mismo producto con stock=1, resultando en stock negativo.
- **Riesgo**: Sobreventa de inventario. Órdenes confirmadas sin stock real.
- **Causa**: La validación de disponibilidad inicial (`validateAvailability`) es no-bloqueante. Sin locking en la reserva, dos transacciones concurrentes podían leer `stock_quantity=1` antes de que alguna descuente.
- **Fix**: `BatchReserveProducts` en catalog-service usa `SELECT FOR UPDATE` sobre las filas de productos dentro de una transacción. Los `product_ids` se ordenan ascendentemente para prevenir deadlocks. La reserva es all-or-nothing.
- **Test**: `TestBatchReserveProductsInsufficientStock` en `stock_reservation_repository_test.go`.
- **Estado**: Corregido.

### 3. Doble pago ante retry
- **Síntoma**: Un retry de checkout con la misma `Idempotency-Key` podía crear un segundo pago para el mismo `checkout_group_id`.
- **Riesgo**: Doble cobro al comprador.
- **Causa**: La idempotencia del pago no estaba garantizada a nivel de base de datos.
- **Fix**: Unique index sobre `checkout_group_id` en la tabla `payments`. El `idempotency_key` se deriva determinísticamente como `payment-{checkout_group_id}`. Si ya existe un pago, se retorna el existente sin crear uno nuevo.
- **Test**: `TestCreatePaymentIdempotentByCheckoutGroup` en `payment_service_test.go`.
- **Estado**: Corregido.

### 4. Duplicación de órdenes en retries
- **Síntoma**: Un retry de checkout creaba órdenes duplicadas para el mismo seller dentro del mismo grupo.
- **Riesgo**: Inflación de órdenes. Comprador ve compras repetidas. Stock y pagos inconsistentes.
- **Causa**: Sin constraint de unicidad sobre `(checkout_group_id, seller_id)` en la tabla `orders`.
- **Fix**: Unique index compuesto sobre `(checkout_group_id, seller_id)`. `FindOrCreateCheckoutGroup` usa UPSERT. Las órdenes se crean una sola vez por vendedor dentro del grupo.
- **Test**: `TestCheckoutIdempotencyMultiSeller` en `order_service_test.go`.
- **Estado**: Corregido.

### 5. Privacidad del vendedor vulnerada (SDD9)
- **Síntoma**: Un seller podía potencialmente acceder a órdenes de otros vendedores si conocía el `order_id`.
- **Riesgo**: Fuga de información entre vendedores competidores. Datos de venta, precios y compradores expuestos.
- **Causa**: Las queries de seller no validaban ownership a nivel raíz de `orders.seller_id`, o usaban `order_items.seller_id` que es más débil.
- **Fix**: `GetOrderForSeller` verifica `order.SellerID == userID` sobre la tabla `orders` (no sobre `order_items`). Rutas de seller usan `RequireRole("user")` que excluye al admin. Recursos ajenos retornan 404.
- **Test**: Tests de privacidad en `order_service_test.go` y `order_controller_test.go`.
- **Estado**: Corregido.

### 6. `GrandTotal` inconsistente en checkout groups recuperados
- **Síntoma**: Al recuperar un `CheckoutGroup` existente, `GrandTotal` podía ser 0 si las órdenes hijas ya tenían totales calculados.
- **Riesgo**: Payment por monto incorrecto ($0). Compra regalada.
- **Causa**: El `GrandTotal` del CG se persistía en un paso separado y podía quedar desincronizado si el flujo se interrumpía después de crear órdenes pero antes de actualizar el CG.
- **Fix**: Auto-healing en `InitiateCheckout`: si `GrandTotal == 0` pero hay órdenes, se recalcula sumando los totales de las órdenes hijas y se persiste.
- **Test**: `TestCheckoutAutoHealGrandTotal` en `order_service_test.go`.
- **Estado**: Corregido.

### 7. `pending_stock` como estado inicial del CG (riesgo de naming)
- **Síntoma**: El CG se crea con status `pending_stock` aunque las órdenes ya fueron creadas en el mismo paso. El nombre puede confundir — sugiere que el stock todavía no fue evaluado, cuando en realidad las órdenes ya existen.
- **Riesgo**: Confusión en debugging y documentación. No es un bug funcional.
- **Causa**: Naming heredado de iteraciones tempranas del diseño.
- **Fix**: No corregido aún. El CG transiciona rápidamente a `pending_payment` en el flujo normal. Es una deuda de naming, no de comportamiento.
- **Estado**: Deuda técnica (naming).

## Tests e Integración

### Suite E2E principal

El script `scripts/test/integration/e2e_render_checkout_saga_sdd7.sh` (1830 líneas) contiene la suite completa de tests E2E. Aunque el nombre conserva "sdd7" por historia, cubre SDD7, SDD8 y SDD9 en un solo script. Las suites están organizadas como funciones bash:

- **SDD7**: Cart internal cleanup (`sdd7_cart_cleanup_suite`)
- **SDD8**: Seller order reconciliation + checkout privacy (`sdd8_seller_reconciliation_suite`, `sdd8_checkout_privacy_suite`)
- **SDD9**: Multi-seller checkout + seller isolation + admin read-only (`sdd9_seller_admin_privacy_suite`)

### Scripts disponibles

| Script | Propósito |
|--------|-----------|
| `scripts/test/integration/e2e_render_checkout_saga_sdd7.sh` | Suite E2E completa (SDD7+SDD8+SDD9). 1830 líneas |
| `scripts/test/integration/run_sdd7_local_env.sh` | Wrapper para entorno local (Docker Compose) |
| `scripts/test/integration/run_sdd7_render_real_env.sh` | Wrapper para entorno Render (producción). Incluye preflight de token interno a cart-service |
| `scripts/test/integration.sh` | Orquestador general de integration tests (levanta stack, espera readiness, ejecuta harness) |

**No existen scripts separados `run_sdd8_local_env.sh` ni `run_sdd9_local_env.sh`.** Las suites SDD8 y SDD9 están embebidas dentro del script `e2e_render_checkout_saga_sdd7.sh`.

### Cómo ejecutar

**Entorno local**:
```bash
./scripts/up.sh                                    # Levantar stack
cd scripts/test/integration
./run_sdd7_local_env.sh                            # Ejecutar suite completa
```

**Entorno Render**:
```bash
cd scripts/test/integration
# Requiere credenciales en .env.local o exportadas
./run_sdd7_render_real_env.sh
```

### Qué cubren los tests E2E

- **Flujo feliz multi-vendedor**: Checkout con productos de 2+ sellers, verifica `checkout_group_id`, `orders[]`, estados correctos.
- **Reintento idempotente**: Mismo `Idempotency-Key` 2 veces → misma respuesta, sin duplicados.
- **Reconciliación**: `GET /checkout/attempts/:key` y `GET /checkout-groups/:id` retornan estado correcto.
- **Seller isolation**: Seller A ve sus órdenes, no ve órdenes de Seller B (404).
- **Admin read-only**: Admin ve todas las órdenes pero no puede acceder a endpoints de seller (403).
- **Cleanup de carrito**: Verifica que los items comprados desaparecen del carrito post-checkout.
- **Tracking code**: Verifica que `POST /seller/orders/:id/status` con `tracking_code` persiste correctamente.

### Qué NO cubren los tests E2E

- **Race condition del último ítem**: Cubierto solo en tests unitarios de catalog-service (`stock_reservation_repository_test.go`), no en el script E2E.
- **Pago rechazado**: El script E2E default usa `PAYMENT_SIMULATION_MODE=approved`. Para probar pago rechazado, se debe cambiar la variable o usar el header `X-Payment-Simulation-Status: rejected` manualmente.
- **Timeout de payment / confirm**: Los tests E2E no simulan desconexiones de red ni timeouts.
- **Cancelación con refund**: No cubierto en la suite E2E actual.

### Tests unitarios por servicio

Cada servicio tiene su propia suite de tests unitarios:

| Servicio | Comando | Cobertura destacada |
|----------|---------|---------------------|
| order-service | `go test ./...` | 2700+ líneas de tests de servicio, 1300+ de controlador, 1300+ de repositorio |
| catalog-service | `go test ./...` | 714 líneas de tests de stock reservation repository (reserve, confirm, release, idempotencia, insufficient stock) |
| cart-service | `go test ./...` | 421 líneas de tests de cleanup repository (full removal, partial decrement, idempotent retry, hard delete, transaction rollback) |
| payment-service | `go test ./...` | 635 líneas de tests de servicio (create, refund, idempotencia, estados inválidos) |

## Deudas técnicas y próximos pasos

### Implementación pendiente

| Deuda | Descripción | Impacto |
|-------|-------------|---------|
| **Refund `refund_pending → refunded`** | El refund transiciona a `refund_pending` pero nunca llega a `refunded`. Falta webhook, job asíncrono o endpoint que complete el ciclo. | Cancelaciones con refund quedan en estado intermedio indefinidamente |
| **Restauración de stock en cancelación** | `CancelOrder` dispara refund si tiene payment, pero no restaura stock llamando a `release` en catalog-service. | Stock perdido si se cancela una orden post-confirmación |
| **Cupones en checkout** | La ruta acepta `coupon_code` pero el servicio lo rechaza explícitamente. Endpoints de gestión de cupones son stubs (501). | Sin descuentos funcionales |
| **Filtro por status en `GET /orders` (buyer)** | El historial del comprador no soporta query param `?status=`. El seller y admin sí lo soportan. | El comprador no puede filtrar sus compras por estado |
| **Notificaciones** | No hay notification-service implementado. Sin emails de confirmación, cambio de estado, etc. | Sin comunicación proactiva con usuarios |
| **Retry con backoff / circuit breaker** | order-service no implementa reintentos con backoff ni circuit breaker para llamadas a servicios internos. La idempotencia es la única red de seguridad. | Ante fallos transitorios de red, el checkout falla y requiere reintento manual del frontend |
| **`POST /checkout/quote`** | Endpoint registrado pero retorna 501. | Sin cotización previa sin ejecutar checkout real |
| **Métricas y tracing** | Sin OpenTelemetry ni métricas por `checkout_group_id`. | Debugging de timeouts en producción requiere log manual |
| **Naming `pending_stock`** | El estado inicial del CG se llama `pending_stock` aunque las órdenes ya fueron creadas. | Confusión en debugging; no es bug funcional |

### Mejoras deseables

- **Contract testing**: Validar que los contratos OpenAPI de cada servicio se corresponden con lo implementado.
- **Health check de la saga**: Endpoint que exponga `CheckoutGroup` en estado `compensating` o `payment_approved` sin confirmar, para monitoreo.
- **Simulación de payment provider real**: Actualmente `Provider: "simulated"`. Una integración real con MercadoPago requeriría webhooks asíncronos.
- **Idempotencia en cleanup con reintentos automáticos**: Actualmente si el cleanup falla, el CG queda en `confirmed` con las órdenes confirmadas pero el carrito sucio (no se revierte la compra). Podría agregarse un job que reintente el cleanup pendiente — hoy no hay reintento automático.

## Hallazgos fuera del scope de esta documentación

Los siguientes puntos se detectaron durante la inspección de código pero no se corrigieron por estar fuera del scope de esta tarea (solo documentación). Se listan para conocimiento del equipo:

1. **MarkPaymentApproved es stub (501)**: El endpoint interno `POST /internal/orders/:orderId/mark-payment-approved` existe pero retorna 501. No se usa en el flujo actual (order-service llama a payment-service directamente), pero podría confundir si alguien asume que es un callback funcional.
2. **CreateInternalOrder es stub (501)**: Misma situación. Placeholder sin implementar.
3. **MarkRefundProcessed es stub (501)**: El refund nunca se marca como procesado. Consistente con que `refund_pending → refunded` no está implementado.

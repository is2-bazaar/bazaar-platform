# Multi-Order Model: una orden por vendedor dentro de un checkout group

> Decisiones base: [ADR 0008](../adr/0008-checkout-multi-vendedor-consolidado.md) · [ADR 0009](../adr/0009-checkout-saga-architecture.md) · [Checkout Saga](./checkout-saga.md)

## Resumen

Cuando un comprador hace checkout con productos de múltiples vendedores, el sistema genera **una orden hija por vendedor**, todas agrupadas bajo un mismo `checkout_group_id`. El comprador ve una compra consolidada; cada vendedor ve solo sus órdenes; los estados logísticos (preparación, envío, entrega) son independientes por orden.

## Reglas de modelo

| Dimensión | Checkout group | Orden hija |
|---|---|---|
| Identidad | `checkout_group_id` único por intento de compra | `order_id` único, scoped a un `seller_id` |
| Visibilidad comprador | Ve la compra agrupada con todas las órdenes hijas | Ve el detalle de cada orden dentro del grupo |
| Visibilidad vendedor | No accede al grupo | Ve solo sus órdenes propias |
| Visibilidad admin | Puede consultar grupo y órdenes individuales | Puede consultar cualquier orden |
| Estado de pago | Un único estado de pago/saga para todo el grupo | No tiene estado de pago propio; refleja el del grupo |
| Total | `grand_total` = suma de totales de órdenes hijas | `total` = subtotal de los ítems de ese vendedor |
| Idempotencia | `(buyer_id, idempotency_key)` → un único grupo | `(checkout_group_id, seller_id)` → única orden por vendedor |
| Estados logísticos | No tiene. Se deriva del estado de las órdenes hijas | `pendiente de pago → confirmada → en preparación → enviada → entregada` |
| Tracking code | No tiene | Uno por orden, provisto por el vendedor |

## Una compra, múltiples paquetes, tiempos distintos

Cada vendedor gestiona su orden de forma independiente. Esto significa que:

- **Cada orden tiene su propio ciclo logístico.** El vendedor A puede estar preparando el paquete mientras el vendedor B ya lo despachó.
- **La compra puede llegar en varios paquetes y en momentos diferentes.** El comprador recibe cada envío por separado, con su propio tracking code y transportista.
- **No se sincroniza el avance logístico entre vendedores.** El sistema no espera a que todas las órdenes estén listas para avanzar; cada una progresa a su propio ritmo.
- **El estado agregado del checkout group se deriva del estado de sus órdenes hijas.** No se persiste un estado logístico a nivel grupo; se calcula bajo demanda.

### Derivación del estado agregado del grupo

| Estado del grupo | Condición |
|---|---|
| `pendiente de pago` | Todas las órdenes están en `pendiente de pago` |
| `pago rechazado` | El pago del grupo fue rechazado; todas las órdenes en `pago rechazado` |
| `confirmada` | Todas las órdenes están `confirmada` y ninguna avanzó a preparación |
| `en preparación` | Al menos una orden está `en preparación` y ninguna fue enviada todavía |
| `parcialmente enviada` | Al menos una orden fue `enviada` pero no todas |
| `enviada` | Todas las órdenes enviables fueron `enviadas` |
| `entregada` | Todas las órdenes fueron marcadas como `entregadas` (o el comprador confirmó recepción completa) |
| `cancelada` | Todas las órdenes del grupo fueron canceladas |

## Indicador de novedades para el comprador

El indicador de novedades (badge, notificación, marcador de "hay cambios") se calcula exclusivamente por cambios en las órdenes hijas desde la última vez que el comprador visualizó el detalle del checkout group.

### Reglas

- El sistema registra un timestamp de **última visualización** por `(buyer_id, checkout_group_id)`.
- Cualquier cambio de estado en una orden hija posterior a ese timestamp genera **novedad**.
- Cambios que cuentan como novedad:
  - Transición de estado de la orden (ej. `confirmada → en preparación`).
  - Tracking code agregado o modificado.
  - Cancelación de una orden por parte del vendedor.
  - Reembolso iniciado o procesado sobre una orden.
- Visualizar el detalle del checkout group **reinicia** el indicador (actualiza el timestamp de última visualización).
- El indicador es **por grupo**, no por orden. El comprador ve un solo marcador de novedades en su historial de compras.

### Ejemplo

```text
Compra #9001 (checkout_group_id = G1)
├── Orden #5001 — Vendedor A — Estado: enviada       ← cambió desde la última visita
├── Orden #5002 — Vendedor B — Estado: en preparación ← cambió desde la última visita
└── Orden #5003 — Vendedor C — Estado: confirmada     ← sin cambios

→ Indicador de novedades activo para G1
→ Al entrar al detalle de G1, se resetea el timestamp
→ Próximo cambio en cualquier orden hija reactivará el indicador
```

## Vistas por rol

### Comprador (buyer)

```text
Historial de compras:
┌────────────────────────────────────────────┐
│ Compra #9001                    🔵 novedad │
│ Vendedor A · Vendedor B · Vendedor C       │
│ Total: $18.000 · Parcialmente enviada      │
└────────────────────────────────────────────┘

Detalle de compra:
┌────────────────────────────────────────────┐
│ Compra #9001                               │
│                                            │
│ 📦 Vendedor A — Enviada                    │
│    Tracking: AR123456789                   │
│    Items: Producto X (x2), Producto Y (x1) │
│    Subtotal: $10.000                       │
│                                            │
│ 📦 Vendedor B — En preparación             │
│    Items: Producto Z (x1)                  │
│    Subtotal: $5.000                        │
│                                            │
│ 📦 Vendedor C — Confirmada                 │
│    Items: Producto W (x3)                  │
│    Subtotal: $3.000                        │
│                                            │
│ Total: $18.000                             │
└────────────────────────────────────────────┘
```

### Vendedor (seller)

```text
Mis ventas:
┌────────────────────────────────────────────┐
│ Orden #5001 — $10.000                       │
│ Estado: Enviada · Tracking: AR123456789    │
│ Comprador: Juan · Dirección: Calle 123     │
└────────────────────────────────────────────┘
```

El vendedor **no ve** el checkout group, no ve otras órdenes del mismo grupo, y no conoce la identidad de otros vendedores involucrados en la compra.

## Endpoints relevantes

| Endpoint | Rol | Semántica |
|---|---|---|
| `POST /checkout` | Buyer | Crea checkout group + órdenes hijas |
| `GET /checkout-groups/:id` | Buyer, Admin | Detalle agrupado con todas las órdenes hijas |
| `GET /checkout/attempts/:idempotencyKey` | Buyer | Reconciliación de intento |
| `GET /orders?status=` | Buyer | Historial de compras del comprador |
| `GET /orders/:id` | Buyer | Detalle de una orden individual |
| `GET /seller/orders?status=` | Seller | Listado de órdenes propias del vendedor |
| `GET /seller/orders/:id` | Seller | Detalle de una orden propia |
| `POST /seller/orders/:id/status` | Seller | Avanzar estado logístico de una orden propia |
| `GET /admin/orders/:id` | Admin | Detalle de cualquier orden (solo lectura) |

## Contratos de implementación

- `order-service` es dueño del modelo: crea órdenes hijas, persiste el `checkout_group_id` y resuelve vistas por rol.
- La derivación de estado del grupo es **calculada**, no persistida. Si se persiste en el futuro, debe mantenerse sincronizada de forma idempotente.
- El timestamp de última visualización (`last_viewed_at` por `buyer_id + checkout_group_id`) puede residir en `order-service` o en una tabla ligera dedicada. No requiere consistencia transaccional fuerte; una escritura eventual es suficiente.
- El indicador de novedades se resuelve en el backend para que el frontend solo consuma un flag booleano (`has_updates`).

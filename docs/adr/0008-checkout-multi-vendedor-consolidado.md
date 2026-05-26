# ADR 0008 - Checkout multi-vendedor con órdenes por vendedor agrupadas

## Contexto

El enunciado de Bazaar establece que el carrito puede contener productos de múltiples vendedores y que el equipo debe decidir si el checkout genera una única orden consolidada o una orden por vendedor. Esa decisión impacta directamente en el modelo de órdenes, la experiencia del comprador, las vistas del vendedor, la integración con pagos, el manejo de stock y la tolerancia a reintentos o desconexiones.

En el dominio del marketplace conviven estas necesidades:

- el comprador espera realizar una única compra desde su carrito, con un único flujo de confirmación y pago;
- el carrito puede incluir productos publicados por distintos vendedores;
- cada vendedor debe poder ver y gestionar únicamente sus propias ventas;
- cada vendedor necesita un estado de preparación/envío y un tracking code propio;
- el comprador necesita ver el estado completo de su compra de forma clara;
- el sistema debe evitar dobles compras, dobles cobros y descuentos duplicados de stock ante reintentos o desconexiones;
- las APIs deben minimizar exposición de datos entre vendedores.

Una única orden consolidada para todos los vendedores simplifica la experiencia inicial del comprador, pero complica mucho el dominio operativo: una misma orden podría tener vendedores en distintos estados, varios tracking codes, subtotales parciales y distintas responsabilidades de preparación/envío. En cambio, una orden por vendedor modela de forma más natural la operación del marketplace, pero requiere agrupar esas órdenes para que el comprador no perciba una compra fragmentada.

## Decisión

Se decide que el checkout multi-vendedor de Bazaar será una **única operación de compra para el comprador**, pero generará internamente **una orden por vendedor**.

La implementación real usa el identificador común `checkout_group_id` para agrupar todas las órdenes creadas por el mismo checkout.

Esto significa que:

- el carrito puede contener productos de múltiples vendedores;
- el comprador ejecuta un único checkout;
- el checkout tiene una única `idempotency_key` por intento de compra;
- el backend agrupa los items del carrito por `seller_id`;
- por cada vendedor presente en el carrito se crea una orden independiente;
- todas las órdenes creadas comparten un identificador de grupo de compra;
- cada orden tiene un único `seller_id` real y no ambiguo;
- cada orden tiene sus propios items, subtotal, total, estado y tracking code;
- el vendedor ve y gestiona únicamente sus órdenes;
- el comprador puede ver la compra agrupada como una sola operación, con secciones por vendedor;
- el administrador puede consultar tanto la compra agrupada como las órdenes individuales asociadas.

En términos de producto:

```text
Una compra visible para el comprador = un grupo de órdenes
Una orden operativa = la venta correspondiente a un vendedor
```

Ejemplo:

```text
Compra / Checkout #9001
├── Orden #5001 - Vendedor A - Total $10.000 - Estado en preparación
├── Orden #5002 - Vendedor B - Total $5.000  - Estado enviada
└── Orden #5003 - Vendedor C - Total $3.000  - Estado confirmada
```

## Justificación

Esta decisión busca equilibrar UX y simplicidad operativa.

Desde la perspectiva del comprador, el flujo sigue siendo simple:

- arma un carrito;
- confirma una compra;
- paga una vez;
- recibe un resumen agrupado;
- consulta el estado de su compra desde un único lugar.

Desde la perspectiva del backend y de los vendedores, el modelo queda más natural:

- cada vendedor tiene sus propias órdenes;
- el estado de preparación/envío no se mezcla con el de otros vendedores;
- el tracking code pertenece a una orden concreta;
- el subtotal del vendedor coincide con el total de su orden;
- no hace falta filtrar items ajenos dentro de una misma orden;
- la privacidad entre vendedores es más fácil de garantizar.

## Reglas de modelado

### Grupo de checkout o compra

Debe existir un identificador común que agrupe todas las órdenes generadas por un mismo checkout.

Nombre recomendado:

```text
checkout_group_id
```

También son aceptables nombres como `purchase_id` o `checkout_id`, siempre que la semántica sea clara y se mantenga consistente.

El grupo representa la intención de compra del comprador y debe permitir:

- reconciliar reintentos de checkout;
- mostrar una compra agrupada en el historial del comprador;
- relacionar varias órdenes hijas con un mismo pago o intento de pago;
- auditar el flujo completo de checkout.

### Orden

La entidad `Order` representa la venta operativa de un único vendedor dentro de una compra.

Cada orden debe tener:

- `id` propio;
- `checkout_group_id` o equivalente;
- `buyer_id`;
- `seller_id` obligatorio y no ambiguo;
- dirección de entrega;
- subtotal de los items de ese vendedor;
- total de esa orden;
- estado propio;
- tracking code propio, si corresponde;
- payment id o referencia al pago/grupo, según la estrategia de pagos;
- historial de estados propio;
- items pertenecientes solo a ese vendedor.

Con esta decisión, `Order.seller_id` vuelve a tener significado fuerte: identifica al vendedor dueño de esa orden.

### Items

Cada `OrderItem` pertenece a una única orden y, por construcción, todos los items de esa orden deben pertenecer al mismo vendedor.

Debe contener:

- `order_id`;
- `product_id`;
- `seller_id`;
- nombre del producto al momento de la compra;
- precio unitario al momento de la compra;
- cantidad;
- imagen o referencia visual;
- datos mínimos necesarios para reconstruir la compra sin depender del catálogo.

Aunque `Order.seller_id` sea la fuente principal para la orden, conservar `OrderItem.seller_id` sigue siendo útil para auditoría, validaciones y consultas.

### Pago

La experiencia deseada es que el comprador perciba un único pago por la compra agrupada.

La implementación vigente adopta explícitamente **pago único por grupo de checkout**: un único payment intent por el total global, asociado a `checkout_group_id`.

Esto respeta mejor la UX de una sola compra y obliga a que la consistencia se resuelva a nivel de Saga: si el pago se aprueba, las órdenes del grupo deben quedar alineadas; si falla, el sistema debe compensar stock y estados de forma coherente.

## Reglas de checkout

El checkout debe comportarse como una única operación de negocio.

### Entrada

El frontend inicia checkout enviando:

- dirección de entrega;
- ciudad y provincia;
- idempotency key;
- cupón, si corresponde.

### Agrupación por vendedor

El backend debe:

1. leer el carrito del comprador;
2. validar disponibilidad actual de los items;
3. agrupar los items por `seller_id`;
4. crear un `checkout_group_id` para el intento;
5. crear una orden por cada vendedor;
6. asociar todas las órdenes al mismo grupo;
7. iniciar pago o pagos según la estrategia vigente;
8. confirmar, rechazar o dejar pendiente el grupo de órdenes de forma consistente.

Ejemplo lógico:

```text
cart.items = [
  item seller A,
  item seller A,
  item seller B
]

checkout_group_id = G1

orders = [
  order seller A, checkout_group_id G1, items A,
  order seller B, checkout_group_id G1, items B
]
```

### Idempotencia

La `idempotency_key` identifica un intento lógico de compra del comprador.

La idempotencia debe estar scopiada por comprador:

```text
buyer_id + idempotency_key => un único checkout_group_id y un único conjunto de órdenes
```

Si el comprador reintenta el checkout con la misma key porque perdió conexión, refrescó la pantalla o volvió atrás, el backend debe devolver el grupo y las órdenes ya creadas, sin crear nuevas órdenes, sin volver a cobrar y sin volver a descontar stock.

### Consistencia

La operación debe evitar:

- órdenes duplicadas para el mismo intento;
- cobros duplicados;
- descuentos duplicados de stock;
- órdenes confirmadas sin stock suficiente;
- cobros aprobados sin órdenes asociadas;
- estados divergentes dentro del grupo sin registro o compensación.

La estrategia concreta de consistencia distribuida puede evolucionar, pero debe quedar documentada si se estabiliza como diseño propio. Para una primera implementación, es aceptable una orquestación simple desde `order-service`, siempre que sea idempotente y maneje errores explícitamente.

## Manejo de stock

El checkout debe validar y afectar stock por item.

Reglas esperadas:

- antes de intentar el pago, el sistema debe verificar que todos los items tienen stock suficiente;
- la reducción o reserva de stock debe ser idempotente por checkout/order/item;
- si falla la creación de órdenes o el pago, el stock no debe quedar descontado indebidamente;
- si una orden se cancela antes del envío, se debe restaurar el stock correspondiente a los items de esa orden;
- si se cancela todo el grupo, se debe restaurar stock de todas las órdenes no enviadas del grupo.

La implementación exacta puede usar reserva de stock, descuento al confirmar pago o compensación posterior. Lo importante es que el flujo sea consistente ante fallos parciales.

## Reglas de estado

### Estado por orden

Cada orden tiene su propio ciclo de vida:

```text
pendiente de pago -> confirmada -> en preparación -> enviada -> entregada
```

Estados de excepción:

```text
pago rechazado
cancelada
reembolso en proceso
reembolso procesado
```

Como cada orden pertenece a un único vendedor, el vendedor puede avanzar el estado sin interferir con otros vendedores.

### Estado de compra agrupada

El comprador puede ver un estado agregado del grupo de checkout.

Regla conceptual recomendada:

- `pendiente de pago`: todas las órdenes del grupo están pendientes de pago;
- `pago rechazado`: el pago del grupo fue rechazado o todas las órdenes quedaron rechazadas;
- `confirmada`: todas las órdenes están confirmadas y ninguna avanzó a preparación;
- `en preparación`: al menos una orden está en preparación y todavía no todas fueron enviadas;
- `enviada`: todas las órdenes enviables fueron enviadas;
- `entregada`: el comprador confirmó recepción completa o todas las órdenes fueron marcadas como entregadas según la regla implementada;
- `cancelada`: todas las órdenes del grupo fueron canceladas;
- `parcial`: estado derivado opcional para indicar que hay órdenes en estados distintos relevantes, por ejemplo una enviada y otra todavía confirmada.

No es obligatorio persistir un estado del grupo si puede derivarse correctamente de las órdenes hijas. Si se persiste, debe mantenerse sincronizado de forma idempotente.

## Cancelaciones y reembolsos

### Cancelación por comprador

El comprador puede solicitar cancelación mientras las órdenes no hayan sido enviadas, respetando las reglas del enunciado.

En una compra agrupada, el sistema debe definir si la cancelación del comprador opera sobre:

- todo el grupo de checkout; o
- una orden específica dentro del grupo.

Para simplificar la primera implementación, se recomienda:

- cancelación de comprador sobre todo el grupo mientras ninguna orden esté enviada;
- si alguna orden ya fue enviada, bloquear cancelación global e informar qué parte ya avanzó.

### Cancelación por vendedor

El vendedor cancela únicamente su propia orden.

Esto evita que un vendedor pueda cancelar la parte de otro vendedor dentro de la misma compra.

### Reembolso

Si hubo pago aprobado y luego se cancela una orden o el grupo, el sistema debe iniciar el flujo de reembolso correspondiente.

Con pago único por grupo, una cancelación parcial requiere reembolso parcial. Si el equipo no implementa reembolsos parciales inicialmente, debe restringir cancelaciones parciales o documentar la limitación.

## Manejo de desconexiones y reintentos

El modelo debe contemplar escenarios donde el cliente pierde la respuesta o abandona la pantalla mientras el servidor sigue procesando.

### Cliente se desconecta durante checkout

Si el cliente inicia la compra y se desconecta antes de recibir respuesta:

- el servidor puede haber creado el grupo de checkout;
- el servidor puede haber creado algunas o todas las órdenes;
- el servidor puede haber iniciado el pago;
- el servidor puede haber confirmado o rechazado el pago;
- el cliente no debe asumir que la compra falló.

El frontend debe conservar el intento de checkout en curso y reconciliarlo usando la misma `idempotency_key` o el `checkout_group_id` si ya lo recibió.

### Usuario vuelve atrás durante checkout

Volver atrás en la UI no cancela automáticamente el checkout.

El frontend debe mostrar un estado del tipo:

- `Procesando compra`;
- `Compra en curso`;
- `Verificando estado de tu compra`;
- `Continuar seguimiento`.

Debe evitar disparar un nuevo checkout ciego para el mismo carrito mientras exista un intento pendiente.

### Reintento seguro

Si el comprador reintenta, debe hacerlo con la misma `idempotency_key` del intento original.

El backend debe responder con el grupo y las órdenes ya creadas, o con el estado actual del intento, sin repetir side effects.

## Contrato esperado con frontend

### Checkout

Endpoint principal:

```http
POST /checkout
```

Respuesta recomendada:

```json
{
  "checkout_group_id": "uuid",
  "status": "pendiente de pago|confirmada|pago rechazado|en preparación",
  "grand_total": 18000.0,
  "payment_url": "https://...",
  "orders": [
    {
      "order_id": "uuid-1",
      "seller_id": 10,
      "status": "confirmada",
      "subtotal": 10000.0,
      "total": 10000.0
    },
    {
      "order_id": "uuid-2",
      "seller_id": 20,
      "status": "confirmada",
      "subtotal": 8000.0,
      "total": 8000.0
    }
  ]
}
```

Si el checkout ya había sido procesado para la misma `idempotency_key`, debe devolverse el mismo `checkout_group_id` y el estado actual de sus órdenes.

### Reconciliación de checkout

Se recomienda exponer un endpoint para recuperar el resultado de un intento:

```http
GET /checkout/attempts/:idempotencyKey
```

O una alternativa equivalente:

```http
GET /checkout-groups/:checkoutGroupId
```

Esto permite al frontend resolver casos de timeout, refresh o desconexión sin crear un nuevo checkout.

### Historial comprador

```http
GET /orders?page=1&page_size=10
```

La respuesta puede agrupar por `checkout_group_id` para que el comprador vea compras agrupadas.

Alternativamente, si se devuelven órdenes individuales, el frontend debe poder agruparlas por `checkout_group_id`.

### Detalle comprador

```http
GET /orders/:orderId
```

Devuelve una orden individual.

Para una experiencia agrupada, se recomienda además:

```http
GET /checkout-groups/:checkoutGroupId
```

Este endpoint devolvería el detalle completo de la compra agrupada, incluyendo todas las órdenes hijas.

### Historial vendedor

```http
GET /seller/orders?page=1&page_size=10&status=confirmada
```

Devuelve órdenes del vendedor autenticado. Como cada orden pertenece a un único vendedor, no se requiere filtrar items ajenos dentro de la respuesta.

### Detalle vendedor

```http
GET /seller/orders/:orderId
```

Devuelve la orden del vendedor autenticado, con sus items, subtotal, dirección de entrega y estado.

### Actualización de estado por vendedor

```http
POST /seller/orders/:orderId/status
```

Afecta únicamente esa orden del vendedor autenticado.

### Detalle administrativo

```http
GET /admin/orders/:orderId
```

Devuelve una orden individual en modo solo lectura.

La implementación real no agregó un endpoint administrativo separado. El detalle agrupado se consulta por la ruta compartida buyer/admin:

```http
GET /checkout-groups/:checkoutGroupId
```

con control de acceso por ownership o rol `admin`.

## Alternativas consideradas

### 1. Una única orden consolidada real

Esta alternativa genera una sola orden con items de múltiples vendedores.

Ventajas:

- checkout response inicial más simple;
- el comprador ve naturalmente una única orden;
- el pago único es directo de modelar;
- se parece a la experiencia de compra consolidada desde el punto de vista del cliente.

Desventajas:

- `seller_id` a nivel orden queda ambiguo;
- el vendedor requiere proyecciones filtradas para no ver items ajenos;
- el subtotal del vendedor debe calcularse artificialmente;
- tracking por vendedor requiere una entidad adicional;
- estados por vendedor requieren una entidad adicional o reglas agregadas complejas;
- cancelación parcial y refund parcial se vuelven más difíciles de razonar.

Se descarta porque aumenta el riesgo técnico y complica innecesariamente la operación de vendedores.

### 2. Una orden por vendedor sin agrupación visual

Esta alternativa crea órdenes separadas por vendedor y las muestra como compras independientes al comprador.

Ventajas:

- backend simple;
- vendedor simple;
- estados y tracking naturales.

Desventajas:

- mala UX para el comprador;
- una sola intención de compra aparece fragmentada;
- el historial de compras se vuelve ruidoso;
- dificulta explicar el pago único o el intento único de checkout.

Se descarta porque se quiere preservar la percepción de una única compra.

### 3. Restringir el carrito a un único vendedor

Esta alternativa impide mezclar productos de distintos vendedores en el carrito.

Ventajas:

- simplifica mucho el backend;
- evita estados parciales;
- reduce complejidad de checkout.

Desventajas:

- limita una capacidad esperada por el enunciado;
- empeora la experiencia de marketplace;
- fuerza al comprador a realizar múltiples compras si quiere productos de distintos vendedores;
- no responde correctamente al caso explícitamente contemplado por el TP.

Se descarta porque Bazaar debe comportarse como un marketplace flexible.

## Consecuencias

### Positivas

- cada orden tiene un vendedor único y claro;
- el historial de ventas se simplifica;
- el detalle de venta se simplifica;
- el tracking code queda naturalmente asociado a una orden;
- el estado de preparación/envío queda naturalmente asociado a una orden;
- el subtotal del vendedor coincide con el total de su orden;
- se reduce el riesgo de exponer items de otros vendedores;
- el comprador sigue viendo una experiencia agrupada y simple;
- la arquitectura queda más preparada para cancelaciones o problemas por vendedor.

### Negativas

- se introduce una entidad o identificador de agrupación (`checkout_group_id`);
- el checkout response es más complejo porque puede devolver múltiples órdenes;
- el historial del comprador debe agrupar órdenes;
- si se usa pago único por grupo, hay que manejar consistencia entre pago y múltiples órdenes;
- si se permite cancelación parcial, pueden aparecer reembolsos parciales;
- requiere adaptar tests y contratos para compras agrupadas.

## Consecuencias operativas

Para sostener esta decisión, el equipo debe implementar o revisar:

- `checkout_group_id` o identificador equivalente en órdenes;
- idempotencia de checkout scopiada por comprador;
- endpoint o mecanismo de reconciliación por `idempotency_key` o `checkout_group_id`;
- agrupación de carrito por `seller_id` durante checkout;
- creación atómica o compensable de múltiples órdenes;
- descuento o reserva de stock idempotente por item;
- limpieza de carrito tras checkout confirmado;
- historial comprador agrupado;
- detalle comprador de compra agrupada;
- listado y detalle vendedor basados en órdenes propias;
- callbacks de pago idempotentes;
- reglas para cancelación total o parcial;
- documentación OpenAPI de las nuevas respuestas;
- tests de checkout multi-vendedor;
- tests de reintento con misma idempotency key;
- tests para evitar órdenes duplicadas y dobles cobros.

## Notas de implementación

Esta decisión no obliga a implementar todos los endpoints auxiliares en una única iteración. Sin embargo, desde este ADR queda definido que el modelo objetivo no es una orden consolidada con múltiples vendedores, sino un grupo de órdenes por vendedor.

Como regla de compatibilidad, cualquier endpoint nuevo o refactor de órdenes debe responder esta pregunta:

```text
¿Esta respuesta debe representar una orden individual o una compra agrupada?
```

Si representa una compra agrupada, debe usar `checkout_group_id` o equivalente. Si representa una orden individual, debe asumir que esa orden pertenece a un único vendedor.

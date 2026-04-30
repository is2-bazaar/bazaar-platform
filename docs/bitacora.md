# Bitácora

- si usar monorepo
- si usar `auth-service` y `user-service` por separado o juntos
- por qué se eligió Go
- si `customer` y `seller` serían roles o estados
- qué endpoints dejar para más adelante

### Decisión: fortalecer el manejo de sesión del backoffice

Se tomó la decisión de fortalecer el manejo de sesión de `bazaar-backoffice` para que no dependa solamente del refresh al bootstrap.

Motivo:

- `bazaar-mobile` ya contaba con refresh reactivo ante `401`
- `bazaar-backoffice` podía restaurar la sesión al iniciar, pero no reaccionaba igual de bien cuando el token expiraba durante una sesión activa
- se buscó alinear robustez entre clientes sin forzar exactamente la misma implementación técnica

Decisión tomada:

- mantener `sessionStorage` como storage de sesión del backoffice
- conservar el refresh al iniciar cuando el `access_token` ya expiró
- agregar refresh reactivo ante `401` para requests autenticadas
- compartir una única fuente de verdad de sesión entre `AuthContext` y el cliente HTTP

Esta decisión se refleja también en el ADR sobre consumo de API desde frontends.

### Decisión: alinear `sub` de JWT e IDs internos como `uint`

Fecha: 27/04/2026

Se detectó una inconsistencia entre servicios backend al consumir el claim `sub` del JWT:

- `auth-service` trabaja con cuentas basadas en `gorm.Model`, por lo que el ID canónico de cuenta es `uint`
- algunos servicios esperaban `sub` como UUID
- otros esperaban número o string decimal
- `cart-service` incluso mezclaba `uint` para `GET /cart` y UUID para operaciones de items

Decisión tomada:

- usar `uint` como ID canónico de usuario/cuenta/seller/producto mientras esos dominios sigan modelados con GORM
- emitir `sub` en JWT como string decimal, por ejemplo `"8"`
- mantener parsing tolerante para tokens legacy con `sub` numérico
- rechazar `sub` con formato UUID en los endpoints que representan usuarios/cuentas GORM
- mantener UUID solamente para entidades que ya son UUID reales del dominio, como órdenes y pagos

Cambios aplicados:

- `auth-service` emite `sub` con `strconv.FormatUint(uint64(user.ID), 10)` y tiene test que valida que el claim sea string
- `cart-service` parsea `user_id` como `uint` en todos sus endpoints y conserva `Cart.UserID`, `ProductID` y `SellerID` como `uint`
- `order-service` usa `uint` para `BuyerID`, `SellerID`, `ProductID` y `ChangedBy`, manteniendo UUID para `OrderID`, `PaymentID` y `CouponID`
- el gateway mantiene compatibilidad al convertir `sub` numérico/string a string decimal y reenviar `X-User-ID`
- `cart-service` en compose usa variables `CART_DB_*` para host, puerto, usuario, password y nombre de base; el driver se mantiene como `DB_DRIVER` porque es la clave que el servicio lee, tomando su valor desde `CART_DB_DRIVER`
- el `.env` local de carrito debe apuntar a la base `cart_db`, no a `catalog_db`

Verificación realizada:

- `go test ./...` en `auth-service`
- `go test ./...` en `cart-service`
- `go test ./...` en `order-service`
- validación de compose de `bazaar-platform`
- prueba manual vía gateway: `GET /cart` responde `200` con `sub: "123"` y con `sub: 123`, y responde `401` con `sub` UUID

Nota operativa:

- si existe una base previa de `order-service` con columnas `buyer_id`, `seller_id`, `product_id` o `changed_by` como UUID, se requiere reset local o migración explícita antes de usar el nuevo contrato
- para pruebas end-to-end, `auth-service` debe estar en la rama o commit que contiene el cambio `fix/user_id_as_string`, o tener ese cambio integrado

## Temas de discusión relevados

### 1. Monorepo vs repos separados

Se discutió si convenía mantener todo el backend dentro de un mismo repo o separar componentes en repos distintos. Si bien la decisión del monorepo fue descartada en la reunión del 10/04, existieron otros motivos reales para migrar la estructura de los repositorios.

Puntos que aparecieron:

- simplicidad inicial y menor fricción si todo vive junto
- mayor claridad de ownership al separar gateway, auth, user y otros servicios
- costo operativo y de coordinación al multiplicar repos

### 2. `auth-service` y `user-service` juntos o separados

Se discutió si autenticación, cuentas y perfiles debían resolverse dentro de un mismo servicio o en dos dominios vecinos.

Puntos que aparecieron:

- un solo servicio simplifica el arranque
- separar ayuda a aislar identidad, credenciales y sesiones del dominio de perfiles
- la separación introduce integración entre servicios para alta de usuario y sincronización de perfil

Este tema después quedó formalizado en el ADR sobre separación entre `auth-service` y `user-service`.

### 3. Elección de Go

Se discutió por qué usar Go como lenguaje principal del backend.

Puntos que aparecieron:

- simplicidad para servicios HTTP
- tooling liviano para compilar, correr y dockerizar
- buen manejo de microservicios y CLI operativas
- curva de aprendizaje y tradeoffs frente a alternativas más conocidas por el equipo

### 4. `customer` y `seller`: roles o estados

Se discutió cómo modelar la diferencia entre tipos de usuario dentro del sistema.

Puntos que aparecieron:

- tratarlos como roles separados
- tratarlos como estados o atributos de una misma cuenta
- impacto sobre autorización, backoffice, evolución del dominio y experiencia del usuario

### 5. Qué endpoints dejar para más adelante

Se discutió qué endpoints eran necesarios para el alcance actual y cuáles convenía postergar.

Puntos que aparecieron:

- priorizar endpoints mínimos para login, perfil, catálogo y flujos principales
- evitar exponer contratos prematuros sin uso claro
- dejar algunos endpoints administrativos o internos para etapas futuras

## Observación

Esta bitácora registra conversaciones, dudas y discusiones del proceso.

No reemplaza a los ADR:

- la bitácora documenta el recorrido y las preguntas abiertas
- los ADR documentan decisiones ya tomadas o suficientemente estabilizadas

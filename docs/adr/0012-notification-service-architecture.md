# ADR 0012 - Arquitectura del microservicio de notificaciones

## Status

Accepted / Implemented

## Contexto

Bazaar necesita notificar a sus usuarios sobre eventos relevantes del dominio:

- al vendedor, cuando un producto queda con stock bajo (`product_low_stock`).
- al usuario recién registrado en un dispositivo, con un push de bienvenida (`push_token_registered`).

Estos eventos los producen distintos servicios (`order-service`, `catalog-service`, `user-service`) y la entrega final es un push notification a dispositivos móviles. Acoplar esa entrega de forma síncrona dentro de cada servicio productor tendría varios problemas:

- la latencia y las fallas del proveedor de push (FCM) se propagarían al flujo de negocio (ej. un cambio de estado de orden quedaría bloqueado esperando a que se envíe el push);
- cada servicio tendría que conocer las credenciales del proveedor de push, el formato de los mensajes y la lógica de tokens por dispositivo;
- no habría un único punto donde versionar la integración con el proveedor de push ni la gestión de tokens inválidos.

Se necesita un servicio dedicado que centralice la construcción y el envío de notificaciones push, desacoplado de los servicios productores, y resiliente a fallas del proveedor externo.

## Decisión

Se adopta un **microservicio de notificaciones independiente** (`bazaar-backend-notifications-service`), escrito en **Python**, que actúa como **consumidor de eventos** y centraliza el envío de push notifications.

El servicio expone **dos vías de ingreso** para los eventos de notificación:

1. **Consumo asíncrono desde RabbitMQ** (vía principal): los servicios productores publican eventos en un exchange y el worker los consume y procesa.
2. **HTTP interno de dispatch** (vía secundaria / fallback síncrono): endpoints `POST /internal/dispatch/*` protegidos por token de servicio, que permiten disparar el mismo flujo de notificación de forma directa.

Ambas vías terminan en el mismo `NotificationDispatcher`, que resuelve los tokens de dispositivo del usuario contra `user-service` y delega el envío al proveedor de push.

### Lenguaje y stack

A diferencia de los servicios de dominio core (escritos en Go), el notification-service se implementa en **Python 3.11** con dependencias mínimas:

- `pika` — cliente de RabbitMQ;
- `firebase-admin` — SDK de Firebase Cloud Messaging (FCM);
- `PyJWT` — verificación de tokens JWT;
- `python-dotenv` — carga de configuración.

El envío HTTP a `user-service` usa `urllib` de la stdlib, sin dependencias adicionales. La elección de Python responde a que es un servicio de integración (glue) sin lógica de dominio compleja ni requisitos de rendimiento críticos, donde la velocidad de desarrollo y la disponibilidad de SDKs (firebase-admin) priman sobre el rendimiento.

### Modelo de mensajería (RabbitMQ)

- Exchange `bazaar_notifications` de tipo **`direct`**, **durable**.
- Cola `notifications`, **durable**, bindeada con routing key `notification.push`.
- El consumer usa **`prefetch_count=1`** y **ack manual** (`auto_ack=False`): un mensaje se confirma solo después de procesarse correctamente.
- El payload del mensaje incluye un campo `action` que determina qué método del dispatcher se invoca.

### Política de acknowledgement y reintentos

El `MessageHandler` aplica una política de ack deliberada:

- **JSON inválido** → `basic_nack(requeue=False)`: el mensaje malformado se descarta, no tiene sentido reintentarlo.
- **Error de procesamiento** → `basic_nack(requeue=False)`: un error aquí es **determinístico** (payload inválido, bug de código), por lo que reencolar generaría un loop infinito de redelivery que re-enviaría el push en cada reintento. Se descarta el mensaje.
- **Éxito** → `basic_ack`.

Se documenta explícitamente que un **Dead Letter Queue (DLQ)** puede agregarse más adelante para inspección de mensajes fallidos sin reintroducir el loop de redelivery.

### Resolución de tokens y gestión de dispositivos

El servicio **no almacena** los push tokens, los consulta a demanda contra `user-service` a través de `UserServiceClient`:

- `GET /internal/users/{user_id}/push-tokens` → lista de tokens activos por usuario.
- `POST /internal/push-tokens/deactivate` → da de baja un token inválido.

Cuando FCM reporta que un token ya no es válido (`UNREGISTERED` / `registration-token-not-registered`), el dispatcher invoca la desactivación en `user-service`. Así, la **invalidación de tokens muertos** se realimenta automáticamente y se mantiene la higiene del registro de dispositivos.

### Proveedor de push: FCM

El envío de push se encapsula en **`FCMService`** (Firebase Cloud Messaging), con la interfaz `send(device_token, notification) -> dict`. **Todo el delivery de notificaciones ocurre vía FCM.**

Los `device_token` que recibe `FCMService` son los **tokens nativos del dispositivo**: la app móvil los obtiene mediante una función de Expo que expone el push token nativo del sistema operativo. Ese es el único punto donde interviene Expo; **no participa en el envío** de las notificaciones.

`NotificationDispatcher` depende de la abstracción (recibe un `push_service` por inyección), no de los detalles del SDK, lo que aísla la integración con FCM en un único punto y permite testear la lógica de dispatch con un doble.

### Modo mock para credenciales ausentes

`FCMService` degrada de forma **graceful**: si las variables `FIREBASE_PROJECT_ID`, `FIREBASE_PRIVATE_KEY` y `FIREBASE_CLIENT_EMAIL` no están presentes (o `firebase-admin` no está instalado), el servicio entra en **modo mock** y loguea los envíos en vez de fallar. Esto permite levantar el servicio en desarrollo local sin credenciales reales de Firebase.

Las credenciales de Firebase se construyen **íntegramente desde variables de entorno `FIREBASE_*`** (no desde un archivo JSON en disco). El `FIREBASE_PRIVATE_KEY` se almacena con `\n` literales que se restauran a saltos de línea reales al inicializar el SDK.

### Estados de notificación

Las notificaciones modelan un ciclo de vida explícito (`NotificationState`): `QUEUED → SENT → DELIVERED → CLICKED`, más estados terminales `FAILED` y `SKIPPED`. Estos estados se emiten en los logs (`[NOTIFICATION STATE: ...]`) para trazabilidad operativa. Si un usuario no tiene tokens activos, el dispatch retorna `SKIPPED` (no es un error).

### Autenticación

- **Endpoints HTTP internos de dispatch**: protegidos por header `X-Internal-Service-Token` comparado contra `INTERNAL_SERVICE_TOKEN`. Si el token configurado está vacío, la verificación se omite (modo dev).
- **JWT** (`JWTVerifier`, HS256 con `JWT_SECRET`): verificación de tokens de servicio cuando el evento los incluye, validando firma y expiración.
- Las llamadas salientes a `user-service` también viajan con el `X-Internal-Service-Token`.

### Health checks

El worker levanta un servidor HTTP en un thread daemon que expone:

- `GET /livez` — liveness.
- `GET /readyz` — readiness.

Compartiendo el mismo servidor con los endpoints `POST /internal/dispatch/*`.

### Shutdown graceful

El worker maneja `SIGINT` y `SIGTERM` para cerrar la conexión a RabbitMQ de forma ordenada antes de salir.

## Alternativas consideradas

### 1. Envío de push síncrono dentro de cada servicio productor

Cada servicio (order, catalog) llamaría directamente a FCM. Acopla la latencia y las fallas del proveedor externo al flujo de negocio, duplica la integración con el proveedor en cada repo y dispersa las credenciales. Se descarta a favor de un servicio dedicado.

### 2. Solo HTTP (sin RabbitMQ)

Exponer únicamente los endpoints `/internal/dispatch/*` y que los productores los llamen de forma síncrona. Es más simple pero re-acopla la disponibilidad del notification-service (y del proveedor de push) al flujo del productor. Se mantiene la vía HTTP como **fallback/disparo directo**, pero la vía principal es asíncrona vía RabbitMQ para desacoplar.

### 3. Persistir el registro de push tokens en el notification-service

Tener una tabla propia de tokens por dispositivo. Duplicaría la fuente de verdad: `user-service` ya es el dueño de la relación usuario↔dispositivo. Se opta por **consultar a demanda** contra `user-service` y realimentar las invalidaciones, manteniendo una única fuente de verdad.

### 4. Reencolar mensajes fallidos (requeue=true)

Reintentar automáticamente los mensajes que fallan al procesarse. Como los errores de procesamiento son determinísticos, esto genera un loop infinito de redelivery que re-envía el push en cada intento. Se descarta el requeue; un DLQ es la mejora futura apropiada.

### 5. Implementar el servicio en Go

Mantener consistencia de lenguaje con el resto del backend. Se prefiere Python por velocidad de desarrollo y por la disponibilidad del SDK oficial `firebase-admin`, dado que es un servicio de integración sin lógica de dominio compleja.

## Vulnerabilidades y mitigación

### Push tokens expuestos en logs

Los tokens son identificadores de dispositivo sensibles. **Mitigación**: los logs truncan el token (`device_token[:20]`/`[:24]`) y nunca lo emiten completo.

### Loop infinito de redelivery

Reencolar un mensaje con error determinístico re-envía el push en cada reintento. **Mitigación**: `basic_nack(requeue=False)` en todos los caminos de error; el mensaje se descarta en vez de reintentarse.

### Token de servicio vacío deshabilita la autenticación interna

Si `INTERNAL_SERVICE_TOKEN` está vacío, los endpoints de dispatch quedan abiertos. **Mitigación**: aceptable solo en desarrollo local; en entornos desplegados el token debe configurarse. La validación se activa automáticamente cuando hay token.

### Credenciales de Firebase en variables de entorno

El `FIREBASE_PRIVATE_KEY` es material criptográfico sensible. **Mitigación**: se lee desde el entorno (no se commitea archivo JSON), `firebase-credentials.json` está en `.gitignore`, y la ausencia de credenciales degrada a modo mock en lugar de fallar.

## Consecuencias

### Positivas

- Los servicios productores quedan **desacoplados** de la latencia y las fallas del proveedor de push.
- La integración con el proveedor de push (FCM) está **centralizada** en un único repositorio versionable.
- El envío de push queda **aislado** detrás de una abstracción (`push_service`), lo que facilita testearlo y evolucionar la integración con FCM sin tocar la lógica de dispatch.
- El **modo mock** permite desarrollo local sin credenciales reales de Firebase.
- La **invalidación de tokens muertos** se realimenta automáticamente a `user-service`.
- `user-service` permanece como **única fuente de verdad** de los push tokens.
- Health checks (`/livez`, `/readyz`) y shutdown graceful facilitan la operación en orquestadores.

### Negativas

- Agrega **RabbitMQ** como dependencia de infraestructura para la vía principal.
- Sin **DLQ**, los mensajes que fallan al procesarse se pierden (descartados sin reintento ni inspección).
- Introduce **Python** en un backend mayoritariamente Go, sumando un stack y un toolchain adicional.
- La resolución de tokens es **síncrona contra `user-service`** en cada dispatch: una caída de `user-service` impide enviar notificaciones.

## Notas

La referencia de implementación está en:

- `bazaar-backend-notifications-service/worker/main.py` — entry point, servidor HTTP (health + dispatch), shutdown graceful.
- `bazaar-backend-notifications-service/internal/consumer/rabbitmq.py` — conexión, exchange/queue/binding, `prefetch_count=1`, ack manual.
- `bazaar-backend-notifications-service/internal/consumer/message_handler.py` — ruteo por `action` y política de ack/nack.
- `bazaar-backend-notifications-service/internal/services/notification_dispatcher.py` — orquestación, resolución de tokens, invalidación.
- `bazaar-backend-notifications-service/internal/services/fcm_service.py` — backend FCM, modo mock y detección de tokens inválidos.
- `bazaar-backend-notifications-service/internal/services/user_service_client.py` — cliente HTTP interno hacia `user-service`.
- `bazaar-backend-notifications-service/internal/models/notification.py` — `NotificationState`, `NotificationPayload`, `PushTokenRecord`.
- `bazaar-backend-notifications-service/internal/auth/jwt.py` — verificación JWT HS256.
- `bazaar-backend-notifications-service/internal/config/settings.py` — contrato de configuración por entorno.

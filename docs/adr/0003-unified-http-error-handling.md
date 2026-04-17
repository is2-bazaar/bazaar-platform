# ADR 0003 - Manejo unificado de errores HTTP

## Contexto

Bazaar expone múltiples servicios HTTP independientes (`API Gateway`, `auth-service`, `user-service` y otros dominios que pueden sumarse después). Sin una convención compartida para errores, cada repo podría devolver formatos distintos, nombres de campos incompatibles y códigos de estado inconsistentes.

Eso afecta:

- la experiencia de integración de clientes web y mobile
- la consistencia de la documentación OpenAPI
- el debugging entre servicios
- la capacidad de normalizar respuestas en el gateway

Además, el TP1 del curso estableció una disciplina clara para respuestas de error:

- usar `application/problem+json`
- devolver una estructura compatible con RFC 7807
- incluir `type`, `title`, `status`, `detail` e `instance`

Ese requerimiento funciona como antecedente directo para Bazaar, aunque el sistema actual ya evolucionó en un punto: en vez de limitarse siempre a `type: about:blank`, varios repos usan tipos más específicos como `/problems/invalid-request-body`, `/problems/not-found` o `/problems/bad-gateway`.

## Decisión

Se decide adoptar un manejo unificado de errores HTTP en todo Bazaar basado en `application/problem+json` y en una estructura estable compatible con RFC 7807.

La convención común queda definida así:

- el `Content-Type` de las respuestas de error debe ser `application/problem+json`
- el cuerpo de error debe incluir `type`, `title`, `status`, `detail` e `instance`
- `status` debe coincidir con el código HTTP real de la respuesta
- `instance` debe identificar la ruta HTTP que originó el error
- cada repo puede construir errores con helpers propios, pero debe respetar el mismo contrato externo

También se decide distinguir entre dos responsabilidades:

- el gateway normaliza errores propios de borde
- cada servicio de dominio es responsable por sus errores de negocio, validación y dependencia interna

## Alcance por componente

### API Gateway

El gateway normaliza los errores que nacen en la capa de borde, por ejemplo:

- rate limiting (`429`)
- autenticación/autorización de borde
- políticas de acceso y middleware común
- errores propios del gateway antes de delegar al servicio interno

En estos casos, el gateway responde directamente con `application/problem+json`.

### Servicios de dominio

`auth-service` y `user-service` son responsables de construir y devolver sus propios errores de aplicación, por ejemplo:

- request body inválido (`400`)
- credenciales o tokens inválidos (`401`)
- acceso prohibido por rol o contexto (`403`)
- recurso inexistente (`404`)
- conflictos de dominio (`409`, cuando corresponda)
- dependencias aguas abajo con falla observable (`502`)
- errores internos inesperados (`500`)

El gateway no debe reescribir semántica de negocio que pertenece al servicio dueño del endpoint.

## Alternativas consideradas

### 1. Dejar que cada repo defina su propio formato de error

Ventajas:

- menor coordinación inicial
- libertad total por servicio

Desventajas:

- rompe consistencia entre APIs
- complica clientes y tests de integración
- dificulta documentación y observabilidad comunes

Se descarta porque Bazaar ya opera como sistema compuesto y necesita un contrato de error reconocible entre repos.

### 2. Usar RFC 7807 solamente en el gateway y dejar formatos libres en los servicios

Ventajas:

- centraliza parte del trabajo en un solo componente
- reduce esfuerzo inicial en servicios individuales

Desventajas:

- el gateway tendría que traducir errores ajenos constantemente
- se pierde fidelidad semántica de errores de dominio
- cada servicio seguiría siendo inconsistente cuando se lo consume de forma directa o interna

Se descarta porque traslada demasiada responsabilidad al gateway y no resuelve la uniformidad del sistema.

### 3. Adoptar la disciplina del TP1 como base, pero extender `type`

Ventajas:

- conserva la forma establecida por RFC 7807 y por el TP1
- mantiene un contrato simple para clientes
- permite agregar tipos más descriptivos

Desventajas:

- introduce una pequeña divergencia respecto del baseline más estricto del TP1
- exige coordinar un vocabulario mínimo de problem types entre repos

Se adopta porque conserva la compatibilidad conceptual con el TP1 y mejora expresividad para un sistema de múltiples servicios.

## Consecuencias

### Positivas

- los clientes reciben errores con una forma estable
- los repos comparten una semántica común para `400`, `401`, `403`, `404`, `429`, `500` y `502`
- el gateway puede normalizar solo sus propios errores sin absorber lógica de negocio
- la documentación OpenAPI queda más coherente entre servicios

### Negativas

- exige disciplina para mantener helpers y status codes alineados
- cualquier desviación entre repos se vuelve visible más rápido
- hay que documentar explícitamente cuándo un error pertenece al borde y cuándo pertenece al dominio

## Relación con el TP1

Este ADR toma al TP1 como antecedente metodológico directo:

- el TP1 fijó la necesidad de usar `application/problem+json`
- el TP1 obligó a pensar los errores como parte del contrato HTTP y no como un detalle de implementación
- Bazaar reutiliza esa disciplina como base de consistencia entre servicios

## Notas

En el estado actual del workspace:

- `API Gateway` ya devuelve `application/problem+json` para errores propios como rate limiting
- `auth-service` y `user-service` ya serializan `ErrorResponse` compatibles con RFC 7807
- `auth-service` y `user-service` comparten prácticamente el mismo vocabulario de `problem types`

Si el sistema sigue creciendo, puede ser conveniente extraer estos tipos y helpers a una librería compartida o a una convención formal por versión para evitar incompatibilidades entre repos.

# ADR 0003 - Manejo unificado de errores HTTP

## Contexto

Bazaar expone multiples servicios HTTP independientes (`API Gateway`, `auth-service`, `user-service` y otros dominios que pueden sumarse despues). Sin una convencion compartida para errores, cada repo podria devolver formatos distintos, nombres de campos incompatibles y codigos de estado inconsistentes.

Eso afecta:

- la experiencia de integracion de clientes web y mobile
- la consistencia de la documentacion OpenAPI
- el debugging entre servicios
- la capacidad de normalizar respuestas en el gateway

Ademas, el TP1 del curso establecio una disciplina clara para respuestas de error:

- usar `application/problem+json`
- devolver una estructura compatible con RFC 7807
- incluir `type`, `title`, `status`, `detail` e `instance`

Ese requerimiento funciona como antecedente directo para Bazaar, aunque el sistema actual ya evoluciono en un punto: en vez de limitarse siempre a `type: about:blank`, varios repos usan tipos mas especificos como `/problems/invalid-request-body`, `/problems/not-found` o `/problems/bad-gateway`.

## Decision

Se decide adoptar un manejo unificado de errores HTTP en todo Bazaar basado en `application/problem+json` y en una estructura estable compatible con RFC 7807.

La convencion comun queda definida asi:

- el `Content-Type` de las respuestas de error debe ser `application/problem+json`
- el cuerpo de error debe incluir `type`, `title`, `status`, `detail` e `instance`
- `status` debe coincidir con el codigo HTTP real de la respuesta
- `instance` debe identificar la ruta HTTP que origino el error
- cada repo puede construir errores con helpers propios, pero debe respetar el mismo contrato externo

Tambien se decide distinguir entre dos responsabilidades:

- el gateway normaliza errores propios de borde
- cada servicio de dominio es responsable por sus errores de negocio, validacion y dependencia interna

## Alcance por componente

### API Gateway

El gateway normaliza los errores que nacen en la capa de borde, por ejemplo:

- rate limiting (`429`)
- autenticacion/autorizacion de borde
- politicas de acceso y middleware comun
- errores propios del gateway antes de delegar al servicio interno

En estos casos, el gateway responde directamente con `application/problem+json`.

### Servicios de dominio

`auth-service` y `user-service` son responsables de construir y devolver sus propios errores de aplicacion, por ejemplo:

- request body invalido (`400`)
- credenciales o tokens invalidos (`401`)
- acceso prohibido por rol o contexto (`403`)
- recurso inexistente (`404`)
- conflictos de dominio (`409`, cuando corresponda)
- dependencias aguas abajo con falla observable (`502`)
- errores internos inesperados (`500`)

El gateway no debe reescribir semantica de negocio que pertenece al servicio dueno del endpoint.

## Alternativas consideradas

### 1. Dejar que cada repo defina su propio formato de error

Ventajas:

- menor coordinacion inicial
- libertad total por servicio

Desventajas:

- rompe consistencia entre APIs
- complica clientes y tests de integracion
- dificulta documentacion y observabilidad comunes

Se descarta porque Bazaar ya opera como sistema compuesto y necesita un contrato de error reconocible entre repos.

### 2. Usar RFC 7807 solamente en el gateway y dejar formatos libres en los servicios

Ventajas:

- centraliza parte del trabajo en un solo componente
- reduce esfuerzo inicial en servicios individuales

Desventajas:

- el gateway tendria que traducir errores ajenos constantemente
- se pierde fidelidad semantica de errores de dominio
- cada servicio seguiria siendo inconsistente cuando se lo consume de forma directa o interna

Se descarta porque traslada demasiada responsabilidad al gateway y no resuelve la uniformidad del sistema.

### 3. Adoptar la disciplina del TP1 como base, pero extender `type`

Ventajas:

- conserva la forma establecida por RFC 7807 y por el TP1
- mantiene un contrato simple para clientes
- permite agregar tipos mas descriptivos.

Desventajas:

- introduce una pequeña divergencia respecto del baseline mas estricto del TP1
- exige coordinar un vocabulario minimo de problem types entre repos

Se adopta porque conserva la compatibilidad conceptual con el TP1 y mejora expresividad para un sistema de multiples servicios.

## Consecuencias

### Positivas

- los clientes reciben errores con una forma estable
- los repos comparten una semantica comun para `400`, `401`, `403`, `404`, `429`, `500` y `502`
- el gateway puede normalizar solo sus propios errores sin absorber logica de negocio
- la documentacion OpenAPI queda mas coherente entre servicios

### Negativas

- exige disciplina para mantener helpers y status codes alineados
- cualquier desviacion entre repos se vuelve visible mas rapido
- hay que documentar explicitamente cuando un error pertenece al borde y cuando pertenece al dominio

## Relacion con el TP1

Este ADR toma al TP1 como antecedente metodologico directo:

- el TP1 fijo la necesidad de usar `application/problem+json`
- el TP1 obligo a pensar los errores como parte del contrato HTTP y no como un detalle de implementacion
- Bazaar reutiliza esa disciplina como base de consistencia entre servicios


## Notas

En el estado actual del workspace:

- `API Gateway` ya devuelve `application/problem+json` para errores propios como rate limiting
- `auth-service` y `user-service` ya serializan `ErrorResponse` compatibles con RFC 7807
- `auth-service` y `user-service` comparten practicamente el mismo vocabulario de `problem types`

Si el sistema sigue creciendo, puede ser conveniente extraer estos tipos y helpers a una libreria compartida o a una convencion formal por version para evitar incompatibilidades entre repos.

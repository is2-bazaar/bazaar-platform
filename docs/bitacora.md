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

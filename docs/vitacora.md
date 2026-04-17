# Bitacora

  - si usar monorepo
  - si usar `auth-service` y `user-service` por separado o juntos
  - por que se eligio Go
  - si `customer` y `seller` serian roles o estados
  - que endpoints dejar para mas adelante


### Decision: fortalecer el manejo de sesion del backoffice

Se tomo la decision de fortalecer el manejo de sesion de `bazaar-backoffice` para que no dependa solamente del refresh al bootstrap.

Motivo:

- `bazaar-mobile` ya contaba con refresh reactivo ante `401`
- `bazaar-backoffice` podia restaurar la sesion al iniciar, pero no reaccionaba igual de bien cuando el token expiraba durante una sesion activa
- se busco alinear robustez entre clientes sin forzar exactamente la misma implementacion tecnica

Decision tomada:

- mantener `sessionStorage` como storage de sesion del backoffice
- conservar el refresh al iniciar cuando el `access_token` ya expiro
- agregar refresh reactivo ante `401` para requests autenticadas
- compartir una unica fuente de verdad de sesion entre `AuthContext` y el cliente HTTP

Esta decision se refleja tambien en el ADR sobre consumo de API desde frontends.

## Temas de discusion relevados

### 1. Monorepo vs repos separados

Se discutio si convenia mantener todo el backend dentro de un mismo repo o separar componentes en repos distintos. Si bien la decisión del monorepo fue descartada en la reunión del 10/04, existieron otros motivos reales para migrar la estructura de los repositorios.

Puntos que aparecieron:

- simplicidad inicial y menor friccion si todo vive junto
- mayor claridad de ownership al separar gateway, auth, user y otros servicios
- costo operativo y de coordinacion al multiplicar repos

### 2. `auth-service` y `user-service` juntos o separados

Se discutio si autenticacion, cuentas y perfiles debian resolverse dentro de un mismo servicio o en dos dominios vecinos.

Puntos que aparecieron:

- un solo servicio simplifica el arranque
- separar ayuda a aislar identidad, credenciales y sesiones del dominio de perfiles
- la separacion introduce integracion entre servicios para alta de usuario y sincronizacion de perfil

Este tema despues quedo formalizado en el ADR sobre separacion entre `auth-service` y `user-service`.

### 3. Eleccion de Go

Se discutio por que usar Go como lenguaje principal del backend.

Puntos que aparecieron:

- simplicidad para servicios HTTP
- tooling liviano para compilar, correr y dockerizar
- buen manejo de microservicios y CLI operativas
- curva de aprendizaje y tradeoffs frente a alternativas mas conocidas por el equipo

### 4. `customer` y `seller`: roles o estados

Se discutio como modelar la diferencia entre tipos de usuario dentro del sistema.

Puntos que aparecieron:

- tratarlos como roles separados
- tratarlos como estados o atributos de una misma cuenta
- impacto sobre autorizacion, backoffice, evolucion del dominio y experiencia del usuario

### 5. Que endpoints dejar para mas adelante

Se discutio que endpoints eran necesarios para el alcance actual y cuales convenia postergar.

Puntos que aparecieron:

- priorizar endpoints minimos para login, perfil, catalogo y flujos principales
- evitar exponer contratos prematuros sin uso claro
- dejar algunos endpoints administrativos o internos para etapas futuras

## Observacion

Esta bitacora registra conversaciones, dudas y discusiones del proceso.

No reemplaza a los ADR:

- la bitacora documenta el recorrido y las preguntas abiertas
- los ADR documentan decisiones ya tomadas o suficientemente estabilizadas

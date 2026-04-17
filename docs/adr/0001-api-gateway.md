# ADR 0001 - API Gateway como punto unico de entrada


## Contexto

Bazaar se construye como un sistema con multiples componentes y clientes:

- servicios backend con responsabilidades separadas
- una app mobile
- un backoffice web
- un entorno local integrado para desarrollo

El enunciado del trabajo practico espera un API Gateway como punto unico de entrada al sistema, responsable de centralizar el enrutamiento hacia los servicios backend, la validacion de tokens de sesion y el rate limiting. Ademas, el workspace ya evoluciono hacia una separacion explicita entre modulos, incluyendo repositorios propios para `auth-service`, `user-service`, `catalog-service` y `Bazaar-backend-api-gateway`.

Sin un gateway, cada cliente tendria que conocer la ubicacion de cada servicio, resolver autenticacion contra multiples endpoints y duplicar reglas de acceso, CORS y configuracion de red. Eso aumentaria el acoplamiento entre frontends y backend, y volveria mas costoso cambiar la topologia interna del sistema.

## Decision

Se adopta un API Gateway separado como repositorio y componente explicito de la arquitectura de Bazaar.

El gateway sera el punto unico de entrada para los clientes externos y concentrara responsabilidades de borde:

- enrutamiento hacia servicios internos
- validacion de tokens y middleware comun de autenticacion
- rate limiting de borde sobre endpoints publicos sensibles
- CORS y politicas basicas de acceso desde clientes web
- exposicion unificada de documentacion OpenAPI de los servicios

El gateway no debe contener logica de negocio del marketplace. Las reglas de dominio siguen perteneciendo a cada servicio.

En el estado actual del workspace, el source of truth del gateway es el repositorio `Bazaar-backend-api-gateway/`.

La implementacion vigente del rate limiting en el gateway sigue estas reglas:

- se aplica mediante politicas explicitamente asociadas a rutas del gateway
- usa una estrategia fixed window en memoria indexada por `policy + IP`
- cubre `POST /auth/login`, `POST /auth/forgot-password` y `POST /auth/reset-password`
- responde `429 Too Many Requests`, incluye `Retry-After` y serializa el error como `application/problem+json`
- expone parametros configurables por ambiente para ventana, maximo de requests y frecuencia de limpieza de buckets expirados

## Alternativas consideradas

### 1. Exponer `auth` como prefijo publico generico en lugar de rutas explicitas

Ventajas:

- menos wiring inicial en el gateway
- menor cantidad de rutas declaradas manualmente

Desventajas:

- aumenta el riesgo de publicar accidentalmente endpoints de `auth-service` que no deberian quedar expuestos
- vuelve menos explicita la frontera entre endpoints publicos y protegidos
- dificulta asociar middleware de borde especifico por endpoint sensible

Se descarta porque el gateway necesita controlar de forma explicita que endpoints quedan publicados y que politicas de borde aplica sobre cada uno.

### 2. Aplicar rate limiting global a todo el prefijo `/auth/*`

Ventajas:

- implementacion mas simple
- menor cantidad de politicas para mantener

Desventajas:

- castiga endpoints con perfiles de riesgo distintos usando la misma ventana y el mismo umbral
- vuelve mas facil degradar flujos legitimos como `register`, `refresh` u otros endpoints publicos de menor sensibilidad
- dificulta evolucionar el control de abuso por endpoint segun cambien los requerimientos

Se descarta porque el estado actual del sistema requiere politicas acotadas a rutas puntuales como `login`, `forgot-password` y `reset-password`.

### 3. Resolver el rate limiting solo dentro de `auth-service`

Ventajas:

- permite usar informacion propia del dominio, como cuenta o email
- evita duplicar algunas reglas entre componentes

Desventajas:

- pierde una capa temprana de mitigacion en el borde
- deja pasar mas trafico innecesario hacia servicios internos antes de rechazarlo
- no cubre por si sola casos de proteccion por IP a nivel de entrada del sistema

Se descarta como estrategia unica. El sistema actual combina controles de borde en el gateway con controles especificos dentro de `auth-service` para endpoints sensibles.


## Consecuencias

### Positivas

- los clientes consumen una sola entrada HTTP del sistema
- se centraliza la validacion de tokens y las politicas de acceso de borde
- se centraliza tambien una primera capa de mitigacion de abuso sobre endpoints criticos de autenticacion
- se reduce el acoplamiento entre frontends y servicios internos
- se simplifica la exposicion unificada de OpenAPI para desarrollo e integracion
- permite reubicar o separar servicios internos con menor impacto sobre los clientes

### Negativas

- agrega un componente mas a desarrollar, testear, desplegar y monitorear
- introduce un salto extra en la comunicacion
- si el gateway falla, afecta la entrada completa al sistema

## Consecuencias operativas

Para que esta decision sea sostenible:

- el gateway debe mantenerse sin logica de negocio
- su configuracion de servicios debe ser explicita y documentada
- las politicas de rate limiting deben quedar asociadas a rutas concretas y parametrizadas por configuracion, evitando valores hardcodeados en el wiring de rutas
- debe contar con observabilidad y health checks propios
- las decisiones de autenticacion y rate limiting implementadas en el gateway no reemplazan los controles de autorizacion dentro de cada servicio

## Notas

Esta decision cubre la adopcion del API Gateway como patron y componente arquitectonico. Las decisiones mas especificas sobre:

- estrategia de autenticacion y autorizacion
- evolucion futura de rate limiting hacia storage compartido o enforcement distribuido --> Por ejemplo con Redis
- propagacion de identidad entre servicios
- despliegue y operacion en cloud

se documentaran en ADRs separados si el proyecto las estabiliza como decisiones de arquitectura independientes.

# ADR 0001 - API Gateway como punto único de entrada

## Contexto

Bazaar se construye como un sistema con múltiples componentes y clientes:

- servicios backend con responsabilidades separadas
- una app mobile
- un backoffice web
- un entorno local integrado para desarrollo

El enunciado del trabajo práctico espera un API Gateway como punto único de entrada al sistema, responsable de centralizar el enrutamiento hacia los servicios backend, la validación de tokens de sesión y el rate limiting. Además, el workspace ya evolucionó hacia una separación explícita entre módulos, incluyendo repositorios propios para `auth-service`, `user-service`, `catalog-service` y `Bazaar-backend-api-gateway`.

Sin un gateway, cada cliente tendría que conocer la ubicación de cada servicio, resolver autenticación contra múltiples endpoints y duplicar reglas de acceso, CORS y configuración de red. Eso aumentaría el acoplamiento entre frontends y backend, y volvería más costoso cambiar la topología interna del sistema.

## Decisión

Se adopta un API Gateway separado como repositorio y componente explícito de la arquitectura de Bazaar.

El gateway será el punto único de entrada para los clientes externos y concentrará responsabilidades de borde:

- enrutamiento hacia servicios internos
- validación de tokens y middleware común de autenticación
- rate limiting de borde sobre endpoints públicos sensibles
- CORS y políticas básicas de acceso desde clientes web
- exposición unificada de documentación OpenAPI de los servicios

El gateway no debe contener lógica de negocio del marketplace. Las reglas de dominio siguen perteneciendo a cada servicio.

En el estado actual del workspace, el source of truth del gateway es el repositorio `Bazaar-backend-api-gateway/`.

La implementación vigente del rate limiting en el gateway sigue estas reglas:

- se aplica mediante políticas explícitamente asociadas a rutas del gateway
- usa una estrategia fixed window en memoria indexada por `policy + IP`
- cubre `POST /auth/login`, `POST /auth/forgot-password` y `POST /auth/reset-password`
- responde `429 Too Many Requests`, incluye `Retry-After` y serializa el error como `application/problem+json`
- expone parámetros configurables por ambiente para ventana, máximo de requests y frecuencia de limpieza de buckets expirados

## Alternativas consideradas

### 1. Exponer `auth` como prefijo público genérico en lugar de rutas explícitas

Ventajas:

- menos wiring inicial en el gateway
- menor cantidad de rutas declaradas manualmente

Desventajas:

- aumenta el riesgo de publicar accidentalmente endpoints de `auth-service` que no deberían quedar expuestos
- vuelve menos explícita la frontera entre endpoints públicos y protegidos
- dificulta asociar middleware de borde específico por endpoint sensible

Se descarta porque el gateway necesita controlar de forma explícita qué endpoints quedan publicados y qué políticas de borde aplica sobre cada uno.

### 2. Aplicar rate limiting global a todo el prefijo `/auth/*`

Ventajas:

- implementación más simple
- menor cantidad de políticas para mantener

Desventajas:

- castiga endpoints con perfiles de riesgo distintos usando la misma ventana y el mismo umbral
- vuelve más fácil degradar flujos legítimos como `register`, `refresh` u otros endpoints públicos de menor sensibilidad
- dificulta evolucionar el control de abuso por endpoint según cambien los requerimientos

Se descarta porque el estado actual del sistema requiere políticas acotadas a rutas puntuales como `login`, `forgot-password` y `reset-password`.

### 3. Resolver el rate limiting solo dentro de `auth-service`

Ventajas:

- permite usar información propia del dominio, como cuenta o email
- evita duplicar algunas reglas entre componentes

Desventajas:

- pierde una capa temprana de mitigación en el borde
- deja pasar más tráfico innecesario hacia servicios internos antes de rechazarlo
- no cubre por sí sola casos de protección por IP a nivel de entrada del sistema

Se descarta como estrategia única. El sistema actual combina controles de borde en el gateway con controles específicos dentro de `auth-service` para endpoints sensibles.

## Consecuencias

### Positivas

- los clientes consumen una sola entrada HTTP del sistema
- se centraliza la validación de tokens y las políticas de acceso de borde
- se centraliza también una primera capa de mitigación de abuso sobre endpoints críticos de autenticación
- se reduce el acoplamiento entre frontends y servicios internos
- se simplifica la exposición unificada de OpenAPI para desarrollo e integración
- permite reubicar o separar servicios internos con menor impacto sobre los clientes

### Negativas

- agrega un componente más a desarrollar, testear, desplegar y monitorear
- introduce un salto extra en la comunicación
- si el gateway falla, afecta la entrada completa al sistema

## Consecuencias operativas

Para que esta decisión sea sostenible:

- el gateway debe mantenerse sin lógica de negocio
- su configuración de servicios debe ser explícita y documentada
- las políticas de rate limiting deben quedar asociadas a rutas concretas y parametrizadas por configuración, evitando valores hardcodeados en el wiring de rutas
- debe contar con observabilidad y health checks propios
- las decisiones de autenticación y rate limiting implementadas en el gateway no reemplazan los controles de autorización dentro de cada servicio

## Notas

Esta decisión cubre la adopción del API Gateway como patrón y componente arquitectónico. Las decisiones más específicas sobre:

- estrategia de autenticación y autorización
- evolución futura de rate limiting hacia storage compartido o enforcement distribuido (por ejemplo, con Redis)
- propagación de identidad entre servicios
- despliegue y operación en cloud

se documentarán en ADRs separados si el proyecto las estabiliza como decisiones de arquitectura independientes.

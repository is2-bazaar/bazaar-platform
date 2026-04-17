# ADR 0002 - Separación entre auth-service y user-service

## Contexto

En una etapa inicial del diseño de Bazaar, autenticación, cuentas y perfiles de usuario se pensaban como parte de un mismo servicio. Esa aproximación era razonable para arrancar más rápido porque concentraba en un solo módulo:

- registro e inicio de sesión
- emisión y validación de tokens
- gestión de credenciales y sesiones
- datos de cuenta
- datos de perfil del usuario

Sin embargo, al crecer el workspace y explicitar mejor los límites entre módulos, esa agrupación empezó a mezclar responsabilidades distintas.

En el estado actual del sistema:

- `auth-service` concentra identidad, credenciales, sesiones, tokens, recupero de contraseña y bootstrap de cuentas
- `user-service` concentra perfiles públicos, datos extendidos del usuario y vistas administrativas de cuentas/perfiles
- el `API Gateway` publica ambos dominios bajo prefijos separados y aplica políticas de acceso de borde

Además, hoy existe una integración directa entre ambos servicios: cuando `auth-service` crea una cuenta, intenta crear el perfil correspondiente en `user-service` mediante `POST /internal/profiles`.

## Decisión

Se decide mantener separados `auth-service` y `user-service` como dos componentes distintos, incluso cuando en el origen se consideraba que ambos podían vivir en un mismo servicio.

La separación queda definida así:

- `auth-service` es responsable de autenticación e identidad
- `user-service` es responsable del dominio de perfiles y datos de usuario no sensibles para login

Responsabilidades de `auth-service`:

- registro de cuentas
- login, refresh y logout
- emisión, rotación y validación de tokens
- cambio y recupero de contraseña
- almacenamiento de credenciales, sesiones y estado de cuenta
- consulta de datos mínimos de cuenta cuando forman parte del dominio de identidad

Responsabilidades de `user-service`:

- creación y actualización de perfiles
- exposición de perfiles públicos
- vistas administrativas y agregadas del dominio de usuarios
- almacenamiento de datos extendidos del usuario asociados a una cuenta autenticada

En consecuencia, la relación entre ambos servicios se modela como una colaboración entre dominios vecinos y no como un único servicio partido artificialmente.

## Alternativas consideradas

### 1. Mantener autenticación y perfiles dentro de un único servicio

Ventajas:

- menor cantidad de servicios y despliegues
- menos integraciones HTTP internas
- flujo de alta de usuario más directo

Desventajas:

- mezcla credenciales, sesiones e identidad con datos de perfil y vistas administrativas
- dificulta evolucionar cada dominio con distinto ritmo
- aumenta el riesgo de acoplar endpoints públicos, internos y administrativos en un mismo módulo
- vuelve más difusa la frontera de seguridad alrededor de secretos, tokens y contraseñas

Se descarta porque el sistema ya requiere distinguir claramente entre identidad/autenticación y perfil/usuario.

### 2. Separar `auth-service` y `user-service`

Ventajas:

- define límites de responsabilidad más claros
- aísla mejor el dominio sensible de autenticación
- permite que el dominio de perfiles evolucione sin mezclarlo con credenciales y sesiones
- facilita exponer prefijos y políticas distintas desde el gateway

Desventajas:

- agrega coordinación entre servicios
- introduce integraciones internas que pueden fallar
- obliga a decidir cómo sincronizar la creación de cuenta con la creación de perfil

Se adopta porque representa mejor la arquitectura actual y reduce el acoplamiento conceptual entre dominios distintos.

### 3. Separar los servicios pero resolver la sincronización de perfiles de forma asincrónica desde el inicio

Ventajas:

- reduce acoplamiento temporal entre alta de cuenta y alta de perfil
- evita que `auth-service` dependa en línea del `user-service`

Desventajas:

- agrega complejidad operativa y de consistencia antes de ser necesaria
- requiere infraestructura y observabilidad adicional para eventos, colas o reintentos
- complica el checkpoint actual sin una necesidad proporcional

Se descarta por ahora aunque no descarta una integración asincrónica futura.

## Consecuencias

### Positivas

- el dominio de autenticación queda mejor aislado
- el dominio de perfiles y usuarios puede evolucionar con mayor autonomía
- el gateway puede exponer contratos más claros para `auth` y `user`
- la arquitectura refleja mejor una separación entre identidad y datos de perfil

### Negativas

- registrar una cuenta ya no es una operación enteramente local a un solo servicio
- aparece un punto de acoplamiento entre `auth-service` y `user-service`
- hay que documentar con claridad qué datos son source of truth en cada servicio

## Consecuencias operativas

Para sostener esta decisión:

- `auth-service` no debe absorber lógica de perfil más allá de la coordinación mínima necesaria para dar de alta la cuenta
- `user-service` no debe transformarse en un segundo servicio de autenticación
- los contratos internos entre ambos servicios deben mantenerse explícitos y versionables
- la falla en la creación del perfil debe tratarse como una preocupación operativa conocida y observada

## Notas

En el estado actual, la separación no elimina todo el acoplamiento:

- `auth-service` conoce `USER_SERVICE_URL`
- al registrar una cuenta intenta crear el perfil correspondiente en `user-service`
- el gateway publica rutas distintas para `auth` y `user`, reforzando esa separación a nivel de entrada

Si en una etapa futura el proyecto necesita menor acoplamiento temporal, esta decisión puede complementarse con un ADR específico sobre sincronización asincrónica entre servicios.

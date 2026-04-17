# ADR 0002 - Separacion entre auth-service y user-service

## Contexto

En una etapa inicial del diseño de Bazaar, autenticacion, cuentas y perfiles de usuario se pensaban como parte de un mismo servicio. Esa aproximacion era razonable para arrancar mas rapido porque concentraba en un solo modulo:

- registro e inicio de sesion
- emision y validacion de tokens
- gestion de credenciales y sesiones
- datos de cuenta
- datos de perfil del usuario

Sin embargo, al crecer el workspace y explicitar mejor los limites entre modulos, esa agrupacion empezo a mezclar responsabilidades distintas.

En el estado actual del sistema:

- `auth-service` concentra identidad, credenciales, sesiones, tokens, recupero de contraseña y bootstrap de cuentas
- `user-service` concentra perfiles publicos, datos extendidos del usuario y vistas administrativas de cuentas/perfiles
- el `API Gateway` publica ambos dominios bajo prefijos separados y aplica politicas de acceso de borde

Ademas, hoy existe una integracion directa entre ambos servicios: cuando `auth-service` crea una cuenta, intenta crear el perfil correspondiente en `user-service` mediante `POST /internal/profiles`.

## Decision

Se decide mantener separados `auth-service` y `user-service` como dos componentes distintos, incluso cuando en el origen se consideraba que ambos podian vivir en un mismo servicio.

La separacion queda definida asi:

- `auth-service` es responsable de autenticacion e identidad
- `user-service` es responsable del dominio de perfiles y datos de usuario no sensibles para login

Responsabilidades de `auth-service`:

- registro de cuentas
- login, refresh y logout
- emision, rotacion y validacion de tokens
- cambio y recupero de contraseña
- almacenamiento de credenciales, sesiones y estado de cuenta
- consulta de datos minimos de cuenta cuando forman parte del dominio de identidad

Responsabilidades de `user-service`:

- creacion y actualizacion de perfiles
- exposicion de perfiles publicos
- vistas administrativas y agregadas del dominio de usuarios
- almacenamiento de datos extendidos del usuario asociados a una cuenta autenticada

En consecuencia, la relacion entre ambos servicios se modela como una colaboracion entre dominios vecinos y no como un unico servicio partido artificialmente.

## Alternativas consideradas

### 1. Mantener autenticacion y perfiles dentro de un unico servicio

Ventajas:

- menor cantidad de servicios y despliegues
- menos integraciones HTTP internas
- flujo de alta de usuario mas directo

Desventajas:

- mezcla credenciales, sesiones e identidad con datos de perfil y vistas administrativas
- dificulta evolucionar cada dominio con distinto ritmo
- aumenta el riesgo de acoplar endpoints publicos, internos y administrativos en un mismo modulo
- vuelve mas difusa la frontera de seguridad alrededor de secretos, tokens y contraseñas

Se descarta porque el sistema ya requiere distinguir claramente entre identidad/autenticacion y perfil/usuario.

### 2. Separar `auth-service` y `user-service`

Ventajas:

- define limites de responsabilidad mas claros
- aisla mejor el dominio sensible de autenticacion
- permite que el dominio de perfiles evolucione sin mezclarlo con credenciales y sesiones
- facilita exponer prefijos y politicas distintas desde el gateway

Desventajas:

- agrega coordinacion entre servicios
- introduce integraciones internas que pueden fallar
- obliga a decidir como sincronizar la creacion de cuenta con la creacion de perfil

Se adopta porque representa mejor la arquitectura actual y reduce el acoplamiento conceptual entre dominios distintos.

### 3. Separar los servicios pero resolver la sincronizacion de perfiles de forma asincronica desde el inicio

Ventajas:

- reduce acoplamiento temporal entre alta de cuenta y alta de perfil
- evita que `auth-service` dependa en linea del `user-service`

Desventajas:

- agrega complejidad operativa y de consistencia antes de ser necesaria
- requiere infraestructura y observabilidad adicional para eventos, colas o reintentos
- complica el checkpoint actual sin una necesidad proporcional

Se descarta por ahora aunque no descarta una integración asíncrona futura.

## Consecuencias

### Positivas

- el dominio de autenticacion queda mejor aislado
- el dominio de perfiles y usuarios puede evolucionar con mayor autonomia
- el gateway puede exponer contratos mas claros para `auth` y `user`
- la arquitectura refleja mejor una separacion entre identidad y datos de perfil

### Negativas

- registrar una cuenta ya no es una operacion enteramente local a un solo servicio
- aparece un punto de acoplamiento entre `auth-service` y `user-service`
- hay que documentar con claridad que datos son source of truth en cada servicio

## Consecuencias operativas

Para sostener esta decision:

- `auth-service` no debe absorber logica de perfil mas alla de la coordinacion minima necesaria para dar de alta la cuenta
- `user-service` no debe transformarse en un segundo servicio de autenticacion
- los contratos internos entre ambos servicios deben mantenerse explicitos y versionables
- la falla en la creacion del perfil debe tratarse como una concern operativa conocida y observada

## Notas

En el estado actual, la separacion no elimina todo el acoplamiento:

- `auth-service` conoce `USER_SERVICE_URL`
- al registrar una cuenta intenta crear el perfil correspondiente en `user-service`
- el gateway publica rutas distintas para `auth` y `user`, reforzando esa separacion a nivel de entrada

Si en una etapa futura el proyecto necesita menor acoplamiento temporal, esta decision puede complementarse con un ADR especifico sobre sincronizacion asincronica entre servicios.

# ADR 0001: Servicios backend separados y `bazaar-platform` como orquestador local

## Contexto

Bazaar necesita evolucionar desde un backend monorepo hacia repos separados por servicio, sin perder un entorno local reproducible para el equipo.

El `api-gateway` y el `auth-service` eran parte de `bazaar-backend`, y `bazaar-platform` trataba a ese repo como una unica caja negra ejecutable. Eso deja de servir cuando ambos pasan a repositorios propios y el runtime local sigue necesitando integrarlos.

## Decision

- `api-gateway` pasa a un repo separado: `Bazaar-backend-api-gateway`
- `auth-service` pasa a un repo separado: `bazaar-backend-auth-service`
- `bazaar-platform` pasa a ser el owner del compose local integrado
- `bazaar-platform` sigue sin absorber cloud, deploy remoto ni secretos
- `bazaar-backend` conserva solo los microservicios que todavia no fueron extraidos

## Alternativas descartadas

### Mantener el gateway dentro de `bazaar-backend`

Se descarta porque no acompaña la separacion por servicio pedida para el proyecto.

### Duplicar el gateway temporalmente en dos repos

Se descarta porque introduce dos sources of truth y aumenta el riesgo de drift.

### Mantener el compose integrado dentro de `bazaar-backend`

Se descarta porque `bazaar-platform` debe ser el runtime local compartido una vez que el backend deja de vivir en un solo repo.

## Consecuencias

### Positivas

- el gateway y auth-service tienen ownership claro y repo propio
- el runtime local sigue siendo un comando unico para el equipo
- la extraccion futura de otros servicios no obliga a rediseñar otra vez el entorno local

### Negativas

- `bazaar-platform` ahora conoce paths de mas de un repo backend
- el compose local queda acoplado a convenciones de build cross-repo

## Estado

Aceptado para la separacion inicial del gateway.

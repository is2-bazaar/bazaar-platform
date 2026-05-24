# ADR 0011 — Rate Limiting centralizado con Redis

## Contexto

Hasta ahora Bazaar usaba rate limiters in-memory por proceso: el API Gateway limitaba por IP, y el auth-service limitaba flujos de login y reset-password con conteo en memoria. Esto funciona correctamente en desarrollo o con una sola instancia, pero no escala a entornos con múltiples réplicas: cada instancia mantiene su propia ventana de conteo, y un atacante puede distribuir requests entre instancias para evadir los límites.

El proyecto necesita pasar a un rate limiter centralizado que mantenga una única ventana de conteo compartida entre todas las instancias de un mismo servicio. Redis es la opción natural: es rápido, atómico, soportado por los tres proveedores de nube principales, y fácil de levantar en local con un contenedor Alpine.

## Decisión

Reemplazar los limiters in-memory por limiters centralizados con Redis como backend primario, usando el algoritmo de fixed-window con script Lua atómico (INCR + EXPIRE). Cada servicio mantiene un fallback in-memory para degradación graceful cuando Redis no está disponible.

La implementación se organiza en cinco PRs independientes, uno por repositorio:

1. **bazaar-platform** (este PR): agrega el servicio Redis 7 Alpine al compose local, expone las variables de entorno necesarias, actualiza la validación del contrato de entorno, y documenta la decisión en este ADR.
2. **Bazaar-backend-api-gateway**: introduce la interfaz `RateLimiter`, implementa `RedisRateLimiter` con `go-redis/v9`, extiende el modelo de políticas para soportar métodos, scopes y claves por usuario, y aplica rate limiting a rutas públicas y protegidas con fallback in-memory.
3. **bazaar-backend-auth-service**: extrae la interfaz `RateLimiter`, implementa Redis+fallback para login y reset-password, y preserva el limiter DB existente para forgot-password sin cambios.
4. **bazaar-mobile**: agrega interceptor Axios para 429 con parseo de `Retry-After`, auto-retry solo en GET/HEAD, y mensaje de error visible en auth submissions.
5. **bazaar-backoffice**: extiende `ApiError` con `retryAfter`, configura SWR globalmente para respetar la ventana de reintento, y agrega UX de countdown en LoginPage.

`bazaar-backend-user-service` no requiere cambios: sus rutas quedan cubiertas por las políticas per-user del gateway.

### Algoritmo

Fixed-window con script Lua atómico en Redis:

```lua
local current = redis.call('INCR', KEYS[1])
if current == 1 then
    redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return current
```

- Si `current > max` → HTTP 429 con `Retry-After` (segundos restantes de la ventana).
- Si Redis no responde (timeout, conexión caída) → fallback al limiter in-memory que ya existe.

### Unidades: ventanas y Redis EXPIRE

Las ventanas de rate limiting se configuran en unidades orientadas al dominio de cada servicio, pero Redis EXPIRE siempre recibe **segundos**:

- **API Gateway**: las ventanas se definen en segundos a nivel de variable de entorno (ej. `GATEWAY_USER_RATE_LIMIT_WINDOW_SECONDS=60`). El gateway pasa ese valor directamente al `EXPIRE` del script Lua, sin conversión.
- **Auth Service**: las ventanas se definen en minutos a nivel de variable de entorno (ej. `AUTH_LOGIN_RATE_LIMIT_WINDOW_MINUTES=15`) por legibilidad operativa. El auth-service convierte minutos → segundos (`window * 60`) internamente antes de pasarlo al `EXPIRE` del script Lua.

La invariante es que **Redis EXPIRE siempre recibe segundos**. Cada servicio es responsable de convertir sus unidades de configuración a segundos antes de ejecutar el script Lua atómico.

### Claves en Redis

Las claves usan prefijos por servicio y SHA-256 para no exponer IPs, emails ni user IDs en texto plano:

```
rl:gateway:{policy}:ip:{sha256(ip)}
rl:gateway:{policy}:user:{sha256(userID)}
rl:auth:{flow}:email:{sha256(normalizedEmail)}
```

### Contrato 429 preservado

El contrato de error definido en ADR 0003 se mantiene sin cambios:

```json
{
  "type": "https://bazaar.dev/errors/rate-limit-exceeded",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "Too many requests. Try again in {n} seconds."
}
```

Header `Retry-After: {seconds}` en segundos enteros.

## Alternativas consideradas

### 1. Mantener solo rate limiting in-memory con sticky sessions

Usar sticky sessions en el load balancer para garantizar que cada IP siempre llegue a la misma instancia. No escala bien con balanceadores que rotan por round-robin o least-connections, y agrega acoplamiento con infraestructura que el TP no controla. Se descarta.

### 2. Sliding-window o token-bucket

Algoritmos más precisos pero más complejos de implementar y depurar. Fixed-window es suficiente para los requisitos actuales del TP. Queda como mejora futura si los requisitos de precisión lo justifican.

### 3. Redis sin fallback in-memory

Más simple pero convierte una caída de Redis en una caída total de auth y gateway. En desarrollo local sería un problema si el contenedor de Redis tarda en levantar. El fallback in-memory mantiene la resiliencia sin perder la centralización en producción.

## Vulnerabilidades y mitigación

### INCR sin EXPIRE en primera ejecución

Si el script Lua falla entre INCR y EXPIRE, la clave nunca expira y el rate limit se vuelve permanente para ese key. **Mitigación**: INCR y EXPIRE se ejecutan dentro del mismo script Lua atómico; Redis garantiza atomicidad del script completo.

### Key namespace collision entre servicios

Si dos servicios usan el mismo prefijo de clave, los contadores se mezclan. **Mitigación**: prefijos explícitos por servicio (`rl:gateway:`, `rl:auth:`), y las claves incluyen el nombre de la política y el scope.

### TTL drift entre instancias

Si las instancias tienen relojes desincronizados, la ventana podría no ser exactamente la misma para todas. **Mitigación**: el TTL lo define Redis con `EXPIRE`, no las instancias. La ventana es relativa al momento del primer INCR, independiente del reloj del cliente.

## Consecuencias

### Positivas

- Rate limiting consistente sin importar cuántas instancias del gateway o auth-service estén corriendo
- El fallback in-memory permite desarrollo local sin Redis y degradación graceful en producción
- Las claves hasheadas no exponen PII en Redis (IPs, emails, user IDs)
- El contrato HTTP 429 existente se preserva sin cambios para los frontends
- Cada PR es independiente y reversible: `GATEWAY_REDIS_ENABLED=false` vuelve al limiter in-memory sin cambios de código
- Redis 7 Alpine en local pesa ~30 MB, arranca en <1 segundo y no requiere configuración

### Negativas

- Agrega Redis como dependencia de infraestructura en producción
- La ventana fija (fixed-window) puede permitir bursts en el borde entre ventanas
- Sin Redis Cluster o Sentinel, Redis es un single point of failure (mitigado por el fallback in-memory)

## Notas

La referencia de implementación está en:

- `bazaar-platform/infra/compose/docker-compose.platform.yml` — servicio Redis + env vars para gateway y auth
- `bazaar-platform/defaults.env` — defaults de Redis para todos los servicios
- `bazaar-platform/scripts/ci/validate-env-contract.sh` — validación de contrato de entorno
- `Bazaar-backend-api-gateway/internal/middleware/rate_limit.go` — `RateLimiter` interface, `RedisRateLimiter`, `FallbackRateLimiter`
- `Bazaar-backend-api-gateway/internal/config/config.go` — `RedisConfig`, políticas extendidas
- `bazaar-backend-auth-service/internal/service/rate_limit.go` — `RateLimiter` interface en auth domain

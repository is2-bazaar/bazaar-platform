# ADR 0004 - Consumo de API desde frontends

## Contexto

Bazaar tiene al menos dos clientes frontend con necesidades distintas:

- `bazaar-backoffice`, una aplicación web orientada a administración
- `bazaar-mobile`, una aplicación mobile basada en Expo

Ambos clientes necesitan consumir el backend del sistema de forma consistente, pero no comparten el mismo runtime ni el mismo mecanismo de configuración.

En particular:

- el backoffice corre en navegador y durante desarrollo local usa Vite
- el mobile corre en Expo, incluyendo dispositivo físico o simulador
- ambos necesitan autenticarse contra `auth-service` a través del `API Gateway`
- ambos deben resolver la URL base de API según el entorno

Sin una decisión explícita, cada frontend podría terminar resolviendo la API de una manera distinta, consultando servicios distintos o manejando la sesión con reglas incompatibles.

## Decisión

Se decide que los frontends de Bazaar consuman el backend siempre a través del `API Gateway` como punto único de entrada.

Esto implica:

- `bazaar-backoffice` no consume microservicios internos directamente
- `bazaar-mobile` no consume microservicios internos directamente
- los contratos HTTP compartidos por ambos clientes se definen sobre los endpoints publicados por el gateway

También se decide que la resolución de `base URL` y el manejo de tokens puede variar por plataforma, pero sin cambiar el contrato funcional:

- ambos clientes hablan con el mismo backend expuesto por el gateway
- ambos usan tokens Bearer para endpoints protegidos
- ambos consumen los endpoints de `login`, `refresh` y `logout` publicados por el gateway

## Resolución de base URL por frontend

### Backoffice

En `bazaar-backoffice`, la política es:

- en desarrollo local, el frontend usa rutas relativas `/api/*`
- Vite proxyea esas rutas hacia el gateway
- el target del proxy se resuelve con `BACKOFFICE_API_BASE_URL`, `VITE_API_PROXY_TARGET` o `VITE_API_BASE_URL`
- si no hay override, el fallback local es `http://localhost:8080`

Esto permite:

- evitar problemas de CORS en desarrollo local del navegador
- mantener llamadas same-origin desde la app web
- desacoplar el código del front respecto de una URL absoluta fija

### Mobile

En `bazaar-mobile`, la política es:

- la app usa una `baseURL` absoluta
- esa URL se resuelve con `EXPO_PUBLIC_BACKEND_API_URL`
- si no se define, el fallback local es `http://localhost:8080`

Esto responde a la naturaleza del runtime mobile:

- no existe el mismo esquema de proxy same-origin que en Vite
- el dispositivo físico puede necesitar una URL distinta a `localhost`
- `bazaar-platform` ayuda a inyectar el valor correcto en desarrollo local

## Manejo de autenticación y tokens

### Contrato compartido

Ambos frontends comparten estas reglas:

- usan `POST /auth/login` para obtener `access_token` y `refresh_token`
- usan `POST /auth/refresh` para renovar la sesión
- envían `Authorization: Bearer <access_token>` en endpoints protegidos
- delegan la validación real de tokens al gateway y a los servicios backend

### Backoffice

En `bazaar-backoffice`, la sesión:

- se persiste en `sessionStorage`
- guarda `accessToken` y `refreshToken`
- deriva la identidad de administrador decodificando el `access_token`
- valida que el rol sea `admin` antes de habilitar acceso al backoffice

Cuando la sesión expira:

- intenta refrescar usando `refresh_token` al bootstrap si el `access_token` guardado ya expiró
- también intenta refresh reactivo ante respuestas `401` en requests autenticadas
- si el refresh falla con error de autenticación, limpia la sesión local

### Mobile

En `bazaar-mobile`, la sesión:

- se persiste en `SecureStore` cuando el runtime lo soporta
- usa fallback en memoria cuando `SecureStore` no está disponible
- agrega automáticamente el `access_token` en requests salientes
- intenta refrescar la sesión automáticamente ante respuestas `401`

Si el refresh falla:

- limpia tokens almacenados
- fuerza logout desde el store de autenticación

## Contrato HTTP compartido

Aunque las implementaciones cliente sean distintas, ambos frontends comparten estas expectativas del backend:

- el punto de entrada es el gateway
- los endpoints públicos y protegidos se resuelven según el contrato expuesto por el gateway
- los endpoints protegidos usan Bearer tokens
- las respuestas exitosas siguen el contrato JSON publicado por cada servicio
- las respuestas de error deben ser compatibles con `application/problem+json`

Esto conecta directamente con el ADR de manejo unificado de errores HTTP y con la decisión previa de adoptar al gateway como punto único de entrada.

## Alternativas consideradas

### 1. Permitir que cada frontend consuma servicios internos directamente

Ventajas:

- puede parecer más simple para algún flujo puntual
- evita pasar por una capa intermedia

Desventajas:

- duplica configuración de URLs y políticas de acceso
- expone topología interna a los clientes
- rompe la idea del gateway como contrato común de entrada

Se descarta porque aumenta acoplamiento y vuelve más frágil la evolución del backend.

### 2. Forzar exactamente la misma estrategia técnica de consumo en web y mobile

Ventajas:

- reduce diferencias aparentes entre clientes
- simplifica parte de la documentación conceptual

Desventajas:

- ignora que navegador y Expo tienen restricciones operativas distintas
- no aprovecha el proxy local de Vite para desarrollo web
- no resuelve correctamente el caso de dispositivo físico en mobile

Se descarta porque igualar plataformas distintas a nivel de runtime complica más de lo que simplifica.

### 3. Tener un backend-for-frontend específico para cada cliente

Ventajas:

- permite contratos muy especializados por frontend
- puede aislar lógica de presentación por canal

Desventajas:

- agrega más componentes sin una necesidad actual clara
- duplica lógica de sesión y acceso
- se solapa con responsabilidades ya asumidas por el gateway

Se descarta por ahora porque el `API Gateway` ya cubre la necesidad actual de entrada unificada.

## Consecuencias

### Positivas

- ambos frontends comparten un único punto de entrada backend
- la configuración por entorno queda más predecible
- el backoffice y el mobile pueden adaptarse a su runtime sin romper el contrato común
- la autenticación se apoya en el mismo flujo general de tokens

### Negativas

- hay dos estrategias de implementación cliente para resolver base URL y persistencia de sesión
- hace falta documentar bien las variables de entorno de cada frontend
- cualquier cambio en el contrato del gateway impacta a ambos clientes

## Notas

En el estado actual del workspace:

- `bazaar-platform` centraliza valores operativos de entorno local como `BACKOFFICE_API_BASE_URL` y `MOBILE_API_BASE_URL`
- `bazaar-backoffice` consume la API mediante `/api/*` con proxy local en desarrollo
- `bazaar-mobile` consume la API con `EXPO_PUBLIC_BACKEND_API_URL`

Si en una etapa futura aparecen diferencias funcionales fuertes entre clientes, esta decisión puede revisarse junto con una posible estrategia BFF. Por ahora, el gateway sigue siendo la interfaz común suficiente para ambos frontends.

# ADR 0004 - Consumo de API desde frontends

## Contexto

Bazaar tiene al menos dos clientes frontend con necesidades distintas:

- `bazaar-backoffice`, una aplicacion web orientada a administracion
- `bazaar-mobile`, una aplicacion mobile basada en Expo

Ambos clientes necesitan consumir el backend del sistema de forma consistente, pero no comparten el mismo runtime ni el mismo mecanismo de configuracion.

En particular:

- el backoffice corre en navegador y durante desarrollo local usa Vite
- el mobile corre en Expo, incluyendo dispositivo fisico o simulador
- ambos necesitan autenticarse contra `auth-service` a traves del `API Gateway`
- ambos deben resolver la URL base de API segun el entorno

Sin una decision explicita, cada frontend podria terminar resolviendo la API de una manera distinta, pegandole a servicios distintos o manejando la sesion con reglas incompatibles.

## Decision

Se decide que los frontends de Bazaar consuman el backend siempre a traves del `API Gateway` como punto unico de entrada.

Esto implica:

- `bazaar-backoffice` no consume microservicios internos directamente
- `bazaar-mobile` no consume microservicios internos directamente
- los contratos HTTP compartidos por ambos clientes se definen sobre los endpoints publicados por el gateway

Tambien se decide que la resolucion de `base URL` y el manejo de tokens puede variar por plataforma, pero sin cambiar el contrato funcional:

- ambos clientes hablan con el mismo backend expuesto por el gateway
- ambos usan tokens Bearer para endpoints protegidos
- ambos consumen los endpoints de `login`, `refresh` y `logout` publicados por el gateway

## Resolucion de base URL por frontend

### Backoffice

En `bazaar-backoffice`, la politica es:

- en desarrollo local, el frontend usa rutas relativas `/api/*`
- Vite proxyea esas rutas hacia el gateway
- el target del proxy se resuelve con `BACKOFFICE_API_BASE_URL`, `VITE_API_PROXY_TARGET` o `VITE_API_BASE_URL`
- si no hay override, el fallback local es `http://localhost:8080`

Esto permite:

- evitar problemas de CORS en desarrollo local del navegador
- mantener llamadas same-origin desde la app web
- desacoplar el codigo del front respecto de una URL absoluta fija

### Mobile

En `bazaar-mobile`, la politica es:

- la app usa una `baseURL` absoluta
- esa URL se resuelve con `EXPO_PUBLIC_BACKEND_API_URL`
- si no se define, el fallback local es `http://localhost:8080`

Esto responde a la naturaleza del runtime mobile:

- no existe el mismo esquema de proxy same-origin que en Vite
- el dispositivo fisico puede necesitar una URL distinta a `localhost`
- `bazaar-platform` ayuda a inyectar el valor correcto en desarrollo local

## Manejo de autenticacion y tokens

### Contrato compartido

Ambos frontends comparten estas reglas:

- usan `POST /auth/login` para obtener `access_token` y `refresh_token`
- usan `POST /auth/refresh` para renovar la sesion
- envian `Authorization: Bearer <access_token>` en endpoints protegidos
- delegan la validacion real de tokens al gateway y a los servicios backend

### Backoffice

En `bazaar-backoffice`, la sesion:

- se persiste en `sessionStorage`
- guarda `accessToken` y `refreshToken`
- deriva la identidad de administrador decodificando el `access_token`
- valida que el rol sea `admin` antes de habilitar acceso al backoffice

Cuando la sesion expira:

- intenta refrescar usando `refresh_token` al bootstrap si el `access_token` guardado ya expiro
- tambien intenta refresh reactivo ante respuestas `401` en requests autenticadas
- si el refresh falla con error de autenticacion, limpia la sesion local

### Mobile

En `bazaar-mobile`, la sesion:

- se persiste en `SecureStore` cuando el runtime lo soporta
- usa fallback en memoria cuando `SecureStore` no esta disponible
- agrega automaticamente el `access_token` en requests salientes
- intenta refrescar la sesion automaticamente ante respuestas `401`

Si el refresh falla:

- limpia tokens almacenados
- fuerza logout desde el store de autenticacion

## Contrato HTTP compartido

Aunque las implementaciones cliente sean distintas, ambos frontends comparten estas expectativas del backend:

- el punto de entrada es el gateway
- los endpoints publicos y protegidos se resuelven segun el contrato expuesto por el gateway
- los endpoints protegidos usan Bearer tokens
- las respuestas exitosas siguen el contrato JSON publicado por cada servicio
- las respuestas de error deben ser compatibles con `application/problem+json`

Esto conecta directamente con el ADR de manejo unificado de errores HTTP y con la decision previa de adoptar al gateway como punto unico de entrada.

## Alternativas consideradas

### 1. Permitir que cada frontend consuma servicios internos directamente

Ventajas:

- puede parecer mas simple para algun flujo puntual
- evita pasar por una capa intermedia

Desventajas:

- duplica configuracion de URLs y politicas de acceso
- expone topologia interna a los clientes
- rompe la idea del gateway como contrato comun de entrada

Se descarta porque aumenta acoplamiento y vuelve mas fragil la evolucion del backend.

### 2. Forzar exactamente la misma estrategia tecnica de consumo en web y mobile

Ventajas:

- reduce diferencias aparentes entre clientes
- simplifica parte de la documentacion conceptual

Desventajas:

- ignora que navegador y Expo tienen restricciones operativas distintas
- no aprovecha el proxy local de Vite para desarrollo web
- no resuelve correctamente el caso de dispositivo fisico en mobile

Se descarta porque igualar plataformas distintas a nivel de runtime complica mas de lo que simplifica.

### 3. Tener un backend-for-frontend especifico para cada cliente

Ventajas:

- permite contratos muy especializados por frontend
- puede aislar logica de presentacion por canal

Desventajas:

- agrega mas componentes sin una necesidad actual clara
- duplica logica de sesion y acceso
- se solapa con responsabilidades ya asumidas por el gateway

Se descarta por ahora porque el `API Gateway` ya cubre la necesidad actual de entrada unificada.

## Consecuencias

### Positivas

- ambos frontends comparten un unico punto de entrada backend
- la configuracion por entorno queda mas predecible
- el backoffice y el mobile pueden adaptarse a su runtime sin romper el contrato comun
- la autenticacion se apoya en el mismo flujo general de tokens

### Negativas

- hay dos estrategias de implementacion cliente para resolver base URL y persistencia de sesion
- hace falta documentar bien las variables de entorno de cada frontend
- cualquier cambio en el contrato del gateway impacta a ambos clientes

## Notas

En el estado actual del workspace:

- `bazaar-platform` centraliza valores operativos de entorno local como `BACKOFFICE_API_BASE_URL` y `MOBILE_API_BASE_URL`
- `bazaar-backoffice` consume la API mediante `/api/*` con proxy local en desarrollo
- `bazaar-mobile` consume la API con `EXPO_PUBLIC_BACKEND_API_URL`

Si en una etapa futura aparecen diferencias funcionales fuertes entre clientes, esta decision puede revisarse junto con una posible estrategia BFF. Por ahora, el gateway sigue siendo la interfaz comun suficiente para ambos frontends.

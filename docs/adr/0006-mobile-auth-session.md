# ADR 0006 - Autenticación y manejo de sesión en mobile

## Contexto

`bazaar-mobile` necesita manejar la autenticación de usuarios de forma segura y con
buena experiencia: el usuario inicia sesión una vez y no debería tener que volver a
hacerlo salvo que su sesión expire o cierre sesión explícitamente.

Esto requiere decidir dónde y cómo persistir los tokens, cómo mantener el estado
de autenticación en la app, y cómo comportarse ante una sesión expirada.

Esta decisión complementa el ADR 0004 de consumo de API, que define el contrato
HTTP compartido para login, refresh y logout.

## Decisiones

### 1. Persistencia de tokens en SecureStore

Se decide persistir `access_token` y `refresh_token` en `expo-secure-store`,
que en Android usa el Keystore del sistema y en iOS usa el Keychain.

Las claves usadas son:
- `bazaar_access_token`
- `bazaar_refresh_token`

Las operaciones están encapsuladas en `src/lib/auth/secureStorage.ts`:
- `saveTokens(accessToken, refreshToken)` — persiste ambos tokens
- `getAccessToken()` — lee el access token
- `getRefreshToken()` — lee el refresh token
- `clearTokens()` — elimina ambos tokens (logout)

**No se usa AsyncStorage** para tokens porque AsyncStorage no está cifrado
y expone los datos sensibles en el almacenamiento del dispositivo.

### 2. Estado global de autenticación con Zustand

Se decide mantener el estado de autenticación en un store global usando Zustand,
definido en `src/lib/store/authStore.ts`.

El store expone:
- `isAuthenticated: boolean` — indica si hay una sesión activa
- `setAuthenticated(value: boolean)` — actualiza el estado
- `logout()` — limpia tokens de SecureStore y setea `isAuthenticated` a `false`

Al arrancar la app (`app/_layout.tsx`) se lee el SecureStore con un `useEffect`:
si existe un `access_token` válido, se setea `isAuthenticated` a `true`.
Este estado se usa en toda la app para tomar decisiones de navegación.


### 3. Refresh automático de sesión

Se decide que el refresh del `access_token` ocurra de forma transparente,
sin intervención del usuario, implementado en `src/lib/api/http.ts`.

El flujo es:
1. Cada request saliente incluye el `access_token` en el header `Authorization`
2. Si el servidor responde con `401`, el interceptor de respuesta intenta
   un `POST /auth/refresh` con el `refresh_token` almacenado
3. Si el refresh es exitoso, se persisten los nuevos tokens y se reintenta
   el request original automáticamente
4. Si el refresh falla (token expirado o inválido), se ejecuta `logout()`:
   se limpian los tokens y se setea `isAuthenticated` a `false`
5. Durante el proceso de refresh, los requests concurrentes que también
   reciban `401` se encolan y se reintentan cuando el refresh termina,
   evitando múltiples llamadas simultáneas a `/auth/refresh`

### 4. Persistencia entre instalaciones

Se tiene en cuenta que `SecureStore` persiste entre instalaciones de la misma app
(mismo package name) en Android. Esto puede causar que tokens de una versión
anterior queden activos en una nueva instalación.

La mitigación es que el interceptor de refresh maneja correctamente tokens inválidos:
si el `refresh_token` ya no es válido en el servidor, se ejecuta logout limpiando
el estado. El usuario verá la app normalmente pero deberá iniciar sesión de nuevo.

## Alternativas consideradas

### Usar AsyncStorage para persistir tokens
Se descarta porque AsyncStorage no cifra los datos. En un contexto de marketplace
donde se manejan datos de compras y pagos, exponer tokens en texto plano es
inaceptable desde el punto de vista de seguridad.

### No persistir tokens (sesión solo en memoria)
Se descarta porque obligaría al usuario a iniciar sesión cada vez que cierra
y reabre la app, lo que degrada significativamente la experiencia de uso.

### Manejar el estado de auth con Context API en lugar de Zustand
Se descarta porque Zustand permite acceder y modificar el store desde fuera
del árbol de componentes (por ejemplo, desde los interceptores de Axios),
lo que Context API no soporta sin workarounds.


## Consecuencias

### Positivas
- los tokens están almacenados de forma cifrada en el Keystore/Keychain del dispositivo
- el refresh de sesión es transparente para el usuario y para el código de producto
- el estado de autenticación es consistente en toda la app a través del store global

### Negativas
- SecureStore puede persistir tokens entre instalaciones, requiriendo que el servidor
  valide correctamente la vigencia de los tokens
- la lógica de refresh en el interceptor agrega complejidad a `http.ts`
- en entornos donde SecureStore no está disponible (Expo Go en web), los tokens
  quedan en memoria y no persisten entre recargas

## Notas

El package name de la app es `com.grupo14.bazaar`. Cualquier cambio en este identificador
implicaría que SecureStore trate la nueva instalación como una app distinta,
perdiendo los tokens almacenados. Esto puede usarse intencionalmente en caso de
necesitar forzar logout de todos los usuarios ante un cambio de versión mayor.

La variable de entorno `EXPO_PUBLIC_BACKEND_API_URL` determina contra qué
instancia del backend se autentica la app. En builds de preview para checkpoints
se usa la URL de Railway; en desarrollo local se usa la IP de la máquina o la URL
de Render según el entorno.

De momento definimos que el punto de entrada de la app sea la pantalla de login en lugar de la home por mas que esta última deberia ser el punto de entrada. Esto es porque todavía no tenemos desarrollada la pantalla de menu y perfil donde le podremos mostrar a un usuario no logueado que inicie sesión. Una vez tengamos este menu cambiaremos el punto de entrada para la home y que usuarios no registrados puedan navegar tambien por la home y catálogo.
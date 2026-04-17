# ADR 0005 - Arquitectura del frontend mobile

## Contexto

`bazaar-mobile` es la aplicación mobile de Bazaar, construida con Expo y React Native.
Al iniciar el proyecto se tomaron decisiones fundacionales sobre cómo organizar el código,
qué lenguaje usar y cómo estructurar la comunicación con el backend. Sin estas decisiones, el proyecto podría crecer de forma inconsistente entre el equipo, lo que resultaría en un código poco prolijo y con malas prácticas.

## Decisiones

### 1. TypeScript sobre JavaScript

Se decide usar TypeScript en toda la codebase del frontend mobile.

Esto implica:
- todos los archivos usan extensión `.ts` o `.tsx`
- los tipos de datos compartidos entre capas se definen explícitamente
- los contratos con el backend se modelan con interfaces TypeScript
- se evita el uso de `any` salvo casos excepcionales debidamente justificados

Las razones principales:
- TypeScript permite detectar errores en tiempo de compilación antes de llegar al dispositivo
- los contratos de API quedan documentados en el propio código
- facilita el trabajo en equipo porque los componentes y funciones son autodocumentados
- el ecosistema de Expo y React Native tiene soporte nativo para TypeScript
- Si bien usar Javascript resulta mas sencillo a la hora de desarrollar, termina siendo poco escalable a largo plazo ya que no tiene definiciones tipadas, por lo que también hace mas dificil encontrar errores en el código.

### 2. Modularización por feature

Se decide organizar el código en módulos por funcionalidad bajo `src/features/`,
complementado por componentes y utilidades compartidas bajo `src/components/` y `src/lib/`.

La estructura adoptada es:
```
src/
├── app/               # Rutas de Expo Router
├── components/ui/     # Componentes de UI reutilizables y genéricos
├── features/          # Módulos por dominio (auth, home, catalog, etc.)
│   └── [feature]/
│       ├── components/  # Componentes específicos del feature
│       ├── hooks/       # Lógica del feature encapsulada en hooks
│       ├── api/         # Funciones de acceso al backend
│       ├── schemas/     # Validaciones con Zod
│       └── types.ts     # Tipos específicos del feature
└── lib/               # Utilidades transversales (http, store, theme, auth)
```

Las razones principales:
- agrupa todo lo relacionado a una funcionalidad en un solo lugar
- facilita encontrar, modificar y testear código de un dominio específico
- reduce el acoplamiento entre features
- permite que distintos integrantes trabajen en features distintos con menos conflictos

### 3. Separación de lógica en hooks

Se decide que los componentes de pantalla no contengan lógica de negocio directamente.
Toda lógica que va más allá del renderizado se extrae a custom hooks.

El patrón adoptado es:
- **screen**: orquesta el layout y delega acciones al hook
- **hook**: contiene estado, efectos, validaciones y llamadas a la API
- **api function**: función pura que ejecuta el request HTTP y retorna datos tipados

Ejemplo en el flujo de login:
- `LoginForm.tsx` renderiza el formulario y llama a `useLogin`
- `useLogin.ts` maneja `isLoading`, `error`, validación y navegación post-login
- `authApi.ts` ejecuta el `POST /auth/login` y retorna `AuthSuccessResponse`

Las razones principales:
- los componentes quedan simples y fáciles de leer
- la lógica en hooks es testeable de forma aislada
- permite reutilizar lógica entre pantallas distintas
- sigue el patrón establecido por la comunidad React

### 4. Cliente HTTP centralizado

Se decide centralizar toda la configuración de requests HTTP en `src/lib/api/http.ts`,
usando Axios como cliente base.

`http.ts` implementa:
- instancia Axios con `baseURL` resuelta desde `EXPO_PUBLIC_BACKEND_API_URL`
- **request interceptor**: inyecta automáticamente el header `Authorization: Bearer <token>`
  en cada request saliente
- **response interceptor**: detecta respuestas `401`, intenta refresh automático del token,
  y reintenta el request original con el nuevo token
- manejo de requests concurrentes durante el refresh mediante una cola (`pendingRequests`)
  para evitar múltiples refresh simultáneos
- flag `_retry` en cada request para evitar loops infinitos en el caso de que el refresh
  también falle

Las funciones de API en cada feature importan esta instancia en lugar de usar
`fetch` o una instancia de Axios propia.

Las razones principales:
- un único lugar para modificar headers, timeouts o comportamiento ante errores
- el refresh de sesión ocurre de forma transparente sin lógica en cada componente
- la URL base se resuelve una sola vez desde la variable de entorno
- reduce duplicación de configuración en cada llamada

## Alternativas consideradas

### Usar JavaScript en lugar de TypeScript
Se descarta porque los beneficios de tipado estático superan el costo de setup,
especialmente en un equipo con múltiples integrantes trabajando en paralelo.

### Organizar por tipo de archivo (components/, hooks/, api/)
Se descarta porque dispersa el código de un mismo dominio en múltiples carpetas,
dificultando la navegación y el entendimiento del flujo completo de una feature.

### Lógica de negocio directamente en los componentes
Se descarta porque genera componentes difíciles de leer, de testear y de mantener
a medida que crece la funcionalidad.

### Usar `fetch` nativo en lugar de Axios
Se descarta porque Axios simplifica el manejo de interceptores, la serialización
de JSON y el tratamiento de errores HTTP, que son necesidades concretas del proyecto.

## Consecuencias

### Positivas
- el código es consistente y predecible en toda la codebase
- nuevas features siguen el mismo patrón sin necesidad de decisiones ad-hoc
- el manejo de autenticación en los requests es transparente para el código de producto
- TypeScript documenta los contratos en el propio código

### Negativas
- TypeScript agrega algo de overhead inicial para desarrolladores que no hayan trabajado con el mismo
- la separación en capas requiere crear más archivos por feature
- el patrón de hooks puede resultar sobredimensionado para features muy simples

## Notas

Los tipos del contrato de API con el backend están definidos en `features/auth/types.ts`
y se espera que cada feature defina sus propios tipos a medida que se integren
nuevos endpoints. La instancia HTTP de `lib/api/http.ts` es la única autorizada
para hacer requests al backend; no se permite usar `fetch` directamente ni crear
instancias adicionales de Axios.
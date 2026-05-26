# ADR 0010 - Acceso directo al bucket de Supabase Storage desde el frontend mobile

## Contexto

Bazaar Mobile necesita manejar imágenes asociadas a entidades del sistema: fotos de perfil de usuario e imágenes de productos. El backend (`bazaar-backend-api-gateway` + servicios internos) gestiona los metadatos de estas entidades, pero no es el lugar adecuado para recibir, procesar y almacenar binarios: eso implicaría aumentar el payload de los requests, agregar lógica de almacenamiento en servicios que no son responsables de eso, y escalar recursos del backend para algo que no es lógica de negocio.

Se necesita entonces un mecanismo para que:

1. El frontend pueda subir imágenes a un storage externo y obtener una URL pública persistente.
2. El frontend pueda mostrar imágenes a partir de URLs almacenadas en los recursos del backend.
3. El backend solo almacene la URL resultante como un campo de texto en la entidad correspondiente.

El equipo ya estaba familiarizado con Supabase como solución de base de datos y dispone de Supabase Storage incluido en el mismo plan free. La restricción de tiempo y tamaño del equipo hace que soluciones más complejas sean difíciles de justificar en este punto del proyecto.

## Decisión

El frontend mobile accede directamente a Supabase Storage usando el SDK de `@supabase/supabase-js` configurado con la `publishable key` (anon key). No se implementa un proxy propio ni un endpoint en el backend para intermediar las operaciones de storage.

El flujo adoptado para la foto de perfil es:

1. El usuario selecciona o saca una foto.
2. El frontend valida tipo MIME y tamaño, comprime la imagen a WebP y la sube directamente al bucket correspondiente en Supabase Storage.
3. Supabase retorna un path dentro del bucket; el frontend construye la URL pública con `getPublicUrl`.
4. El frontend llama al backend, enviando esa URL como el campo `image`.
5. El backend almacena la URL y la devuelve en futuros request get.
6. Al cargar el perfil u productos, el frontend muestra la imagen usando la URL almacenada en el backend, sin pasar por intermediarios.

La implementación reside en `src/features/images/` dentro de `bazaar-mobile`, con la siguiente estructura:

```
features/images/
├── services/
│   ├── imageHelper.ts     # validación, generación de path, compresión
│   ├── storageService.ts  # cliente Supabase, upload, URLs públicas/firmadas
│   └── index.ts           # barrel de exports
├── hooks/
│   ├── useImageUpload.tsx # hook reutilizable para subir imágenes
│   └── useImageUrl.tsx    # hook para resolver URLs de storage
└── components/
    └── ImagePicker.tsx    # componente de selección de imagen
```

## Alternativas consideradas

### 1. Proxy de storage propio en el backend

El backend recibiría el binario (multipart o base64), lo almacenaría en Supabase y devolvería la URL al frontend.

Ventajas:
- el backend mantiene control total sobre qué se sube y quién puede subir
- las políticas de acceso se pueden centralizar en la lógica propia

Desventajas:
- agrega una capa innecesaria de transferencia de datos: el binario viaja frontend → backend → Supabase en lugar de frontend → Supabase
- el backend debe escalar para absorber el ancho de banda de transferencia de imágenes
- aumenta la complejidad de implementación y operación en el contexto del TP
- el beneficio real de seguridad es bajo si las RLS policies de Supabase están bien configuradas

Se descarta por el overhead operativo que introduce frente a un beneficio de seguridad que se puede obtener con políticas de RLS adecuadas.

### 2. Supabase Storage con autenticación propia de Supabase

Cada usuario se autenticaría también contra Supabase Auth, y las RLS policies usarían `auth.uid()` para restringir el acceso por usuario.

Ventajas:
- control por usuario sin depender de la lógica del frontend
- políticas más finas: cada usuario solo puede escribir en su propio path

Desventajas:
- Bazaar Mobile usa su propio sistema de autenticación (JWT emitido por `auth-service`), no Supabase Auth
- mantener dos sistemas de identidad sincronizados (Bazaar Auth + Supabase Auth) es costoso y propenso a inconsistencias
- agrega complejidad sin que el dominio del TP lo justifique

Se descarta porque introduciría una doble identidad difícil de mantener en el scope del proyecto.

### 3. Cloudinary u otro servicio dedicado de gestión de imágenes

Ventajas:
- transformaciones de imagen on-the-fly (resize, crop, format)
- CDN integrado y optimización automática

Desventajas:
- agrega una dependencia externa adicional con su propia curva de setup y costos
- Supabase Storage cubre los requisitos actuales del TP sin costo extra

Se descarta porque no aporta valor diferencial para el scope y los volúmenes del proyecto.

## Vulnerabilidades y mitigación

### Uploads no autenticados (ausencia de identidad Supabase)

El cliente de Supabase en `bazaar-mobile` opera sin sesión de Supabase Auth. Las RLS policies de los buckets  permiten operaciones al rol `anon`. Esto significa que cualquier persona con la anon key puede intentar subir imágenes al bucket.

**Mitigación aplicada:**
- el path de cada imagen incluye el `userId` del usuario autenticado en Bazaar (`users/{userId}/xxx.webp`), lo que hace que los paths sean predecibles pero no colisionantes
- el tamaño máximo aceptado está limitado a 5 MB por archivo en la validación del frontend (`imageHelper.ts`)
- los buckets aceptan solo tipos MIME permitidos (JPEG, PNG, WebP)

**Mitigación pendiente / deuda técnica:** sin autenticación Supabase, un actor malicioso podría subir archivos arbitrarios al bucket usando la anon key directamente. Para proyectos con mayores requerimientos de seguridad, la solución es integrar Supabase Auth o implementar el proxy propio descripto en la alternativa 1.

### Cómo bloquear a un usuario específico

Con la arquitectura actual (acceso directo con anon key y sin Supabase Auth), no existe un mecanismo nativo en Supabase para bloquear a un usuario individual de Bazaar, ya que Supabase no tiene noción de esa identidad.

Las opciones disponibles para bloquear a un usuario son:

**Opción A — Control en el backend:**
El backend puede rechazar el request de un usuario bloqueado, impidiendo que la URL de una nueva imagen se registre. El usuario podría subir binarios al bucket pero no asociarlos a su perfil. Si además se borra manualmente el contenido del usuario en Supabase, el bloqueo es efectivo en la práctica.

**Opción B — Migrar a Supabase Auth como identidad complementaria:**
Si cada usuario de Bazaar tuviese un usuario equivalente en Supabase Auth, las RLS policies podrían usar `auth.uid()` para denegar operaciones de un usuario específico deshabilitando su cuenta en Supabase. Esta opción requiere mantener sincronizados ambos sistemas de identidad.

**Opción C — Proxy propio de storage:**
Implementar el endpoint de upload en el backend permite que cualquier control de acceso basado en el JWT de Bazaar (usuario bloqueado, cuenta suspendida, etc.) se aplique antes de que la imagen llegue a Supabase.

## Consecuencias

### Positivas

- las imágenes no transitan por el backend, reduciendo carga y ancho de banda en los servicios propios
- Supabase Storage provee CDN y URLs públicas persistentes sin infraestructura adicional
- la implementación está encapsulada en `features/images/` y es reutilizable para imágenes de productos u otras entidades
- el backend permanece agnóstico al proveedor de storage: solo almacena una URL de texto
- el costo operativo es cero dentro del plan gratuito de Supabase para los volúmenes esperados del TP

### Negativas

- sin Supabase Auth, el control de acceso por usuario individual es indirecto
- los uploads anónimos al bucket son posibles si alguien extrae la key y las policies no los restringen suficientemente

## Deuda técnica

| Item | Impacto | Acción sugerida |
|---|---|---|
| Uploads sin identidad Supabase | Medio | Integrar Supabase Auth o implementar proxy en el backend si se requiere control por usuario |
| Imágenes antiguas no se borran automáticamente del bucket al cambiar la foto de perfil | Bajo | Implementar limpieza manual periódica o agregar lógica de borrado en el backend al actualizar el campo `image` |
| Validación de tipo MIME solo en el cliente | Medio | Agregar validación server-side en el backend antes de persistir la URL, o en una Supabase Edge Function al momento del upload |
| Sin límite de uploads por usuario en Supabase | Bajo | Agregar rate limiting en el frontend o migrar a proxy propio con control explícito |

## Notas

La referencia de implementación está en:
- `bazaar-mobile/src/features/images/` — lógica de storage
- `bazaar-mobile/src/lib/store/userStore.ts` — integración con el flujo de edición de perfil

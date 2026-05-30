# Integración de Supabase Storage para manejo de imágenes

## Resumen

`bazaar-mobile` sube y consume imágenes directamente desde Supabase Storage, sin pasar por los servicios backend propios. El backend almacena únicamente la URL pública resultante como campo de texto en la entidad correspondiente.

La decisión de arquitectura que justifica este enfoque está documentada en [ADR 0010](../adr/0010-supabase-storage-direct-access.md).

---

## Flujo de upload (foto de perfil)

```
EditProfileScreen
  │
  ├─ Usuario elige imagen del dispositivo (expo-image-picker)
  │     └─ avatarPreviewUri = file:///...  (URI local, solo para preview)
  │
  └─ onSave()
        │
        └─ userStore.saveProfile()
              │
              ├─ isLocalImageUri(avatarUrl) → true
              │
              ├─ imageHelper.getFileSizeBytes()   — valida que no supere 5 MB
              ├─ imageHelper.validateImage()       — valida tipo MIME (JPEG/PNG/WebP)
              ├─ imageHelper.generateImagePath()   — genera path único: users/{userId}/{uid}.webp
              ├─ imageHelper.compressImage()       — convierte a WebP (calidad 0.85) con expo-image-manipulator
              │
              ├─ FileSystem.readAsStringAsync()    — lee el archivo comprimido como base64
              ├─ decode(base64) → ArrayBuffer
              │
              ├─ supabase.storage.from('avatars').upload(path, arrayBuffer)
              │     └─ Supabase Storage guarda el binario y confirma el path
              │
              ├─ getPublicUrl(bucket, path)
              │     └─ construye URL pública permanente:
              │        https://{project}.supabase.co/storage/v1/object/public/avatars/{path}
              │
              ├─ updateMyProfile({ image: publicUrl })
              │     └─ PATCH /users/me → backend persiste la URL en la BD
              │
              └─ mapProfileResponseToUserProfile(response)
                    └─ avatarUrl = response.image  (URL de Supabase, fuente de verdad)
```

---

## Flujo de descarga (visualización de imagen)

```
ProfileScreen / EditProfileScreen
  │
  └─ useUserStore → profile.avatarUrl
        │
        └─ userStore.loadProfile()
              │
              ├─ GET /users/me → backend devuelve { image: "https://...supabase.co/..." }
              │
              └─ mapProfileResponseToUserProfile()
                    └─ avatarUrl = profile.image  (URL pública de Supabase)

<Image source={{ uri: profile.avatarUrl }} />
  └─ React Native descarga la imagen directamente desde la CDN de Supabase
     sin intermediarios ni requests al backend propio
```

No hay lógica de resolución de URL en el cliente: la URL almacenada en el backend es directamente consumible. El bucket `avatars` es público, por lo que no requiere tokens ni URLs firmadas.

---

## Estructura del código

```
src/features/images/
├── services/
│   ├── imageHelper.ts
│   │     Responsabilidades: validación de tipo y tamaño, generación de path único,
│   │     compresión a WebP con expo-image-manipulator, lectura de tamaño con expo-file-system.
│   │
│   ├── storageService.ts
│   │     Responsabilidades: inicialización del cliente Supabase (anon key),
│   │     upload de ArrayBuffer, obtención de URL pública, URL firmada para buckets privados,
│   │     eliminación de archivos.
│   │
│   └── index.ts
│         Barrel de exports públicos del módulo.
│
├── hooks/
│   ├── useImageUpload.tsx
│   │     Hook reutilizable para flujos de pick + upload en un paso.
│   │     Expone: localUri, uploadedUrl, status, loading, error, pickAndUpload(), reset().
│   │
│   └── useImageUrl.tsx
│         Hook para resolver URLs de storage (público o firmado) a partir de un path.
│
└── components/
    └── ImagePicker.tsx
          Componente de selección de imagen reutilizable.
```

La integración con el perfil de usuario no usa `useImageUpload` directamente; el upload ocurre dentro de `userStore.saveProfile()` para mantener la atomicidad del flujo: si el upload falla, no se llama al backend.

---

## Configuración del bucket en Supabase

| Propiedad | Valor |
|---|---|
| Nombre | `avatars` |
| Visibilidad | Público |
| Tamaño máximo | 5 MB (validado en cliente) |
| Tipos permitidos | JPEG, PNG, WebP (validado en cliente) |
| Formato de almacenamiento | WebP (conversión en cliente antes del upload) |

### RLS policies aplicadas

```sql
-- Cualquier usuario (incluso sin sesión Supabase) puede subir imágenes
CREATE POLICY "Allow anon insert to avatars"
ON storage.objects FOR INSERT TO anon
WITH CHECK (bucket_id = 'avatars');

-- Lectura pública sin restricciones (bucket público)
CREATE POLICY "Allow public select from avatars"
ON storage.objects FOR SELECT TO public
USING (bucket_id = 'avatars');

-- El mismo rol puede actualizar y eliminar
CREATE POLICY "Allow anon update avatars"
ON storage.objects FOR UPDATE TO anon
USING (bucket_id = 'avatars');

CREATE POLICY "Allow anon delete from avatars"
ON storage.objects FOR DELETE TO anon
USING (bucket_id = 'avatars');
```

El rol `anon` corresponde a requests autenticados únicamente con la anon key, sin sesión de usuario de Supabase Auth. Ver [ADR 0010](../adr/0010-supabase-storage-direct-access.md) para la justificación y las implicancias de seguridad.

Lo mismo se replica para el bucket 'product-images' para las imagenes de productos

---

## Variables de entorno

| Variable | Descripción |
|---|---|
| `EXPO_PUBLIC_SUPABASE_URL` | URL del proyecto de Supabase (`https://{ref}.supabase.co`) |
| `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Anon key del proyecto. Es pública por diseño; su alcance está acotado por las RLS policies. |

Ambas variables deben usar el prefijo `EXPO_PUBLIC_` para ser accesibles en el bundle de React Native. Variables sin ese prefijo no son inyectadas por el bundler de Expo.

---

## Convención de paths en el bucket

```
avatars/
└── users/
    └── {userId}/
        └── {timestamp36}-{random8}.webp
```

Ejemplo: `users/3/moxf52cw-krhe6dv3.webp`

Cada upload genera un archivo nuevo con nombre único. Las versiones anteriores de la imagen de un mismo usuario permanecen en el bucket hasta ser eliminadas manualmente. Ver deuda técnica en [ADR 0010](../adr/0010-supabase-storage-direct-access.md).

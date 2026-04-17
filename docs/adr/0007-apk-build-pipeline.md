# 007 - Pipeline de build y deploy del APK Android

## Contexto

`bazaar-mobile` necesita generar APKs instalables para que el corrector pueda
probar la aplicación en cada checkpoint del cuatrimestre. Sin un proceso automatizado,
cada build requeriría configuración manual, dependería del entorno local de cada
integrante y sería difícil de reproducir de forma consistente.

Se necesita decidir cómo buildear el APK, dónde hostear el resultado y cómo
distribuirlo al corrector.

## Decisiones

### 1. EAS Build como herramienta de build

Se decide usar **EAS Build** (Expo Application Services) como herramienta para
compilar el APK Android.

EAS Build corre en los servidores de Expo en la nube, lo que implica:
- no se requiere Android Studio, Java ni SDK de Android en la máquina del desarrollador
- el entorno de build es reproducible y controlado por Expo
- el resultado es un APK firmado listo para instalar en cualquier dispositivo Android

La configuración está en `eas.json` en la raíz del proyecto. Se usan tres perfiles:
- `development`: para desarrollo con Expo Go y cliente de desarrollo
- `preview`: genera un APK instalable directamente (no AAB), distribución interna
- `production`: para publicación en stores (no usado actualmente)

El profile `preview` tiene `buildType: "apk"` explícito porque por defecto
EAS genera un AAB que requiere la Play Store para instalarse.

### 2. Variables de entorno por perfil de build

Se decide inyectar la URL del backend directamente en el `eas.json` bajo el perfil
`preview`, en lugar de depender del `.env` local del desarrollador.

```json
"preview": {
  "distribution": "internal",
  "android": {
    "buildType": "apk"
  },
  "env": {
    "EXPO_PUBLIC_BACKEND_API_URL": "https://bazaar-backend-api-gateway-production.up.railway.app"
  }
}
```

Esto garantiza que el APK generado siempre apunte al backend de Railway
(usado para demos y checkpoints) independientemente del `.env` local
de quien dispara el build.

El `.env` local sigue siendo independiente y apunta a Render o a la IP local
según el entorno de desarrollo de cada integrante.

### 3. GitHub Actions como pipeline de CI/CD

Se decide automatizar el build del APK con un workflow de GitHub Actions
definido en `.github/workflows/build-android.yml`.

El workflow:
- se dispara únicamente con tags que siguen el patrón `v*` (ej: `v0.1.0`, `v1.0.0`)
- no se dispara en cada push a main para conservar el cupo de builds gratuitos de EAS
- corre en un runner `ubuntu-latest` de GitHub
- usa `expo/expo-github-action@v8` para configurar EAS en el runner
- ejecuta `eas build --platform android --profile preview --non-interactive --wait`
  para buildear y esperar el resultado antes de continuar
- obtiene la URL del APK desde EAS con `eas build:list`
- crea un **GitHub Release** con el tag como versión y la URL del APK en la descripción

El job requiere el permiso `contents: write` para poder crear releases.

La autenticación con EAS se realiza mediante el secret `EXPO_TOKEN`, que debe
estar configurado en los secrets del repositorio de GitHub. Este token se genera
en el dashboard de expo.dev y nunca se commitea en el código.

### 4. Distribución mediante GitHub Releases

Se decide exponer el APK al corrector a través de la sección **Releases** del
repositorio de GitHub, en lugar de enviarlo por otros medios o hostear el binario
directamente.

Cada release incluye:
- el tag de versión (ej: `v0.1.0`)
- un título descriptivo (ej: `Release v0.1.0 — Checkpoint 1`)
- un link de descarga directa al APK hosteado en los servidores de EAS

El README incluye un link que apunta a `releases/latest`, permitiendo
acceder siempre al APK más reciente en dos clicks.

Los APKs quedan disponibles en EAS por 30 días desde la fecha de build.

### 5. Convención de versiones para checkpoints

Para crear y publicar un release:

```bash
git checkout main
git pull
git tag v0.1.0
git push origin v0.1.0
```

Esto dispara el workflow automáticamente. El corrector puede acceder al APK
desde la tab Releases del repositorio o mediante el link que se le comparte
por Slack.

## Alternativas consideradas

### Build local con EAS (`--local`)
EAS soporta buildear localmente en la máquina del desarrollador con el flag `--local`.
Esto requiere tener Java, Android SDK y ANDROID_HOME configurados correctamente.

Se descarta como método principal porque:
- la configuración del entorno local varía entre integrantes del equipo
- agrega complejidad de setup que no aporta al desarrollo diario
- el build en la nube de EAS es más reproducible y no depende del entorno local

Se mantiene como alternativa durante el desarrollo y para pruebas, ya que buildear en el servidor de expo consume del cupo mensual limite para el free tier, ademas de consumir minutos del cupo de github actions.

### Disparar el build en cada push a main
Se descarta porque el plan gratuito de EAS otorga 30 builds mensuales para Android.
Con múltiples integrantes mergeando a main varias veces por semana, el cupo
se agotaría rápidamente. Disparar solo con tags da control explícito sobre
cuándo se consume un build.

### Subir el APK directamente al release de GitHub
GitHub permite adjuntar archivos binarios a un release. Se evalúa subir el APK
directamente en lugar de linkearlo desde EAS.

Se descarta porque los APKs pueden superar los límites de tamaño de GitHub
y porque EAS ya provee hosting confiable para los binarios. El link en la
descripción del release es suficiente.

### Usar Fastlane u otras herramientas de CI mobile
Herramientas como Fastlane permiten automatizar builds nativos de Android e iOS.

Se descarta porque requieren configuración del entorno nativo completo y son
innecesariamente complejas para un proyecto Expo managed workflow. EAS Build
está diseñado específicamente para este caso de uso.

## Consecuencias

### Positivas
- el proceso de build es completamente automatizado y reproducible
- cualquier integrante puede publicar un release con tres comandos de git
- el corrector siempre tiene acceso al APK más reciente desde un lugar conocido
- el APK del checkpoint apunta al backend de producción (Railway) sin necesidad
  de modificar configuración
- el cupo de builds gratuitos de EAS se conserva al buildear solo con tags

### Negativas
- el build en la nube tarda entre 15 y 20 minutos desde que se dispara el tag y pueden llegar a tardar 1 hora si hay fila para comenzar el build (por el free tier)
- los APKs en EAS expiran a los 30 días, por lo que links viejos dejan de funcionar
- si el corrector necesita el APK urgentemente y hay cola en EAS, hay que recurrir
  al build local como contingencia

## Notas

El package name del APK es `com.grupo14.bazaar`, definido en `app.json`.
Cambiar este identificador en el futuro haría que Android trate la nueva versión
como una app distinta, perdiendo datos persistidos (incluidos los tokens de SecureStore).

El `EXPO_TOKEN` debe configurarse como secret en GitHub antes de que el workflow
pueda ejecutarse. Si el token expira o se revoca, el workflow falla en el paso
de autenticación con EAS. En ese caso hay que generar un nuevo token en expo.dev
y actualizarlo en los secrets del repositorio.

Para builds de contingencia locales, los pasos necesarios son:
1. Configurar `JAVA_HOME` apuntando al JDK de Android Studio
2. Configurar `ANDROID_HOME` apuntando al SDK de Android
3. Ejecutar `eas build --platform android --profile preview --local`
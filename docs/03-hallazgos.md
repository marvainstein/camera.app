# 03 — Hallazgos del análisis estático (IPA v1.8.5 y v1.12.1)

Fecha: 2026-10-19. Herramienta: `scripts/inspect_ipa.sh` (solo lectura de recursos, sin ejecutar nada).
Nivel de evidencia: **observado** = leído en el bundle; *inferido* = deducido de nombres o tamaños.

## Procedencia de la muestra — leer primero

- Archivo: `Leica_LUX__Pro_Photo_Capture-v1.2-ipaomtk.com.ipa`, de un sitio de IPAs de terceros. El nombre dice
  v1.2, pero el `Info.plist` dice **1.8.5 (build 188)**, compilada con Xcode 26.0 en sept. 2025. La versión
  actual en la App Store es 2.0.1, así que faltan Halation, Bloom, Perspective Control, Quick Menu nuevo, etc.
- **Es una copia crackeada**, no la oficial: `cryptid 0` (descifrada), firma ad‑hoc, y 5 dylibs inyectadas
  más `CydiaSubstrate` (ElleKit):
  - `Tg_Sa1y0miii.dylib` → intercepta RevenueCat (`product_entitlement_mapping`, recibo) para desbloquear Pro.
  - `StopReviews.dylib` → bloquea `SKStoreReviewController`.
  - `zxPluginsInject.dylib`, `sideloadKeychainfix1/2.dylib` → parches de sideload (App Groups, keychain).
  - `cyan.entitlements` en la raíz → la armaron con el inyector "Cyan".
- **No instalar esta IPA en ningún dispositivo**: tiene código de terceros desconocido.
- Consecuencia práctica: los **recursos** son fiables (vienen del build de Leica); el **binario** está
  modificado. Para la versión actual conviene repetir el análisis con la IPA oficial (ipatool o Configurator).

## Arquitectura de la app

**Codename interno: "Tyson"** (módulo `Tyson`, `Tyson.SceneDelegate`, targets `TysonWidgets`,
`TysonLockedCameraCaptureExtension`). La app se arma con paquetes Swift internos (de `WhatToTest.en-US.txt`,
que viene con las notas de TestFlight y la lista de dependencias):

| Paquete | Versión | Rol (*inferido* por nombre/contenido) |
|---|---|---|
| `tyson-core` | 1.3.11 | Captura / estado de cámara |
| `tyson-pipeline` | 1.8.1 | Pipeline de render (bokeh, profundidad) |
| `tyson-looks` | 1.13.4 | Looks, grano, shaders Metal (`TysonLooks_TysonLooks.bundle/default.metallib`) |
| `tyson-gallery` | 1.6.7 | Galería propia |
| `leica-ui` | commit | Design system compartido (fuente LG1056, íconos, samples de Looks) — probablemente compartido con Leica FOTOS |
| `grip-sdk` | commit | SDK de Fjorden (`FjordenSDK.framework`) para grips Bluetooth |
| `avfoundation-shim` | 1.7.0 | Capa sobre AVFoundation (testeable) |

Stack de terceros observado:

| Área | SDK |
|---|---|
| Arquitectura | Point‑Free: `swift-dependencies`, `swift-clocks`, `combine-schedulers`, `swift-custom-dump`, `swift-snapshot-testing` (no hay TCA en la lista) |
| UI | SwiftUI + UIKit, Lottie (onboarding), TipKit, videos MP4 de onboarding |
| Persistencia | Core Data (15 `.mom`) y SwiftData |
| Suscripciones | RevenueCat 5.31 + RevenueCatUI (paywall) |
| Analytics / atribución | Amplitude, AppsFlyer, Facebook SDK (con IDFA desactivado por defecto), SKAdNetwork vía AppsFlyer |
| Marketing / push | Salesforce Marketing Cloud (`aps-environment` production, `remote-notification`) |
| Cuenta | OAuth contra Leica Club (Salesforce Experience Cloud, `club.leica-camera.com`) + sync de contacto a Salesforce |
| Crashes | Sentry 8.56 + MetricKit |
| Grip / BLE | CoreBluetooth, `ios-nrf-connect-device-manager` (MCUmgr/DFU), `swiftcbor`, `ios-corebluetooth-mock` |
| Debug | **Atlantis (Proxyman) incluido en producción** (`NSBonjourServices: _Proxyman._tcp`) |

Extensiones: widget (`com.apple.widgetkit-extension`) y captura desde la pantalla bloqueada
(`com.apple.securecapture`, framework `LockedCameraCapture`). Ambas incluyen su propia copia del metallib de Looks.
App Intents (`Metadata.appintents`) y un control de Control Center.

Integraciones: URL scheme `leica-lux://`; consulta `leicaFotos://` y `darkroom://` (abrir en otra app).
iCloud KV store (`ubiquity-kvstore`) para sincronizar preferencias.

> Observación de seguridad: el `Info.plist` lleva en texto plano client IDs **y client secrets** de OAuth
> (prod/test/dev), la API key de RevenueCat, la de Amplitude, la dev key de AppsFlyer, tokens de Marketing Cloud y el DSN de Sentry.
> No los copiamos acá ni deben usarse.

## Pipeline de imagen

### Looks ("Tones")

- `TysonLooksAssets.framework/Assets/Tones/*.data`: 17 archivos de exactamente 2 097 152 bytes.
- **Formato (observado)**: LUT 3D **64×64×64, RGBA float16**, R varía más rápido, luego G y después B; alfa = 1.
  Se carga directo como `MTLTexture` 3D (`lutProfileTexture`).
- Nombre = `<Look>_<espacio entrada>_<espacio salida>_Release[_opacity_NN].data`. Hay LUTs en **sRGB** y en
  **Display P3** (`DP3`). Classic y Contemporary se aplican con opacidad 65 %.
- Looks en esta versión: Standard (`Leica_Base_V3`), Classic, Contemporary, Vivid, Natural, Chrome, Bleach,
  Brass, Eternal, Teal, Blue, Selenium, Sepia, Monochrome Natural / High Contrast, "100 Years" Mono, Greg Williams
  (Sepia 0/100). Colecciones: Color / Monochrome / Artist, y packs "Core" (gratis) y "Essential" (Pro).
- Ajustes por Look en la UI: **Intensity**, **Contrast**, **Grain**.
- Shader: `applyTones` / `applyTonesWithOpacityChange` con `lutProfileTexture`, `secondaryLutTexture`,
  `lutBlendFactor`, `isMonochromeLUT` → *inferido*: interpola entre dos LUTs (p. ej. intensidad, o Sepia 0↔100).

### Grano

- Kernels `filmGrainBooleanModel`, `applyFilmGrainBooleanModel`, `gaussianGrain`, `gaussianGrainGregWilliams`;
  parámetros `grainRadius`, `grainRadiusMax`, `grainSigma`.
- *Inferido*: el "boolean model" es el modelo estocástico de grano de película publicado (granos como discos de
  radio aleatorio, Newson et al. 2017), con una alternativa gaussiana más barata. Es un método académico
  público que podemos implementar.

### Simulación de lente / bokeh

- Shaders: `psfBlur`, `psfUpsample`, `frontBokehBlur`, `blendFrontBokeh`, `blendFrontAndBackBokeh`,
  `fbLayerStartDepths`, `fbLayerRefCOCs`, `cocRadiusLimit`, `apertureDiameter`, `LensFunction`, `focusDepth`,
  `averageFocalDepth`, `depthAveragePersonHorizontal/Vertical`, `personFoundIndicator`, `matteFiltering`,
  `layeredModeFilter`, `undersampledDepthMap`, `appendDepthToRGB`, `softLook`, y un camino barato para el
  preview (`previewBlurHor/Ver`, gaussiano separable).
- En 1.8.5 **no hay modelos CoreML** en el bundle (en 1.12.1 aparece uno, ver abajo) → la profundidad viene de AVFoundation (`AVDepthData`) y la
  segmentación de persona de Vision/matte de Apple (*inferido* por `personFoundIndicator`, sin `.mlmodelc`).
- *Inferido*, el algoritmo:
  1. Mapa de profundidad → limpieza (filtro de moda por capas + filtrado guiado por el matte).
  2. Foco: punto tocado o profundidad promedio de la persona detectada.
  3. Se divide la escena en **capas de profundidad** (delante/detrás del plano de foco), cada una con su
     círculo de confusión (CoC) según la apertura simulada.
  4. Cada capa se desenfoca convolucionando con la **PSF medida de esa lente y apertura**, se reescala y se
     compone de atrás hacia adelante.
  5. En el visor en vivo, se usa una aproximación gaussiana.
- Assets por lente (carpeta `<focal>_f<apertura máxima×10>`):
  - `PSF/<lente>/<focal>-f<N>.data` → una PSF por cada apertura (366 368 bytes; formato no decodificado).
  - `LSP/<lente>/LSP_<focal>mmf<N>_S_40.jpg` → imágenes 1024×768 por apertura; *inferido*: previews de
    referencia para la UI de selección de lente.
- Lentes presentes: 26 f/1.5 y 40 f/1.5 (i‑Solaris, bokeh arremolinado), 28 f/1.4, 35 f/1.4, 50 f/1.2
  (Noctilux), 50 f/3.5, 75 f/1.25 (Noctilux), 90 f/1.5, 90 f/2.0, 90 f/2.2 (Thambar, soft focus),
  100 f/1.5, 120 f/2.0, 120 f/2.5, 120 f/2.8 (Thambar), 135 f/3.4 (APO‑Telyt). Las >75 mm son "virtuales"
  sobre el tele.

## Captura y UI

- Formatos: JPEG/HEIC, **ProRAW** o Bayer RAW, 12 MP o 48 MP, "Smart Processing" on/off (el RAW no lleva Look).
- Visor: histograma, focus peaking, grilla, nivel, temporizador, flash, relaciones de aspecto (1:1, 5:4, 4:3,
  3:2, 16:9) con **reencuadre no destructivo** (también en Recompose).
- **Leica Frame**: marco exportable (negro/blanco/amarillo/"Film") con metadatos (copyright, fecha,
  exposición, lente, ubicación).
- Geolocalización en EXIF, modo limitado sin permisos, consentimiento ATT propio, paywall de retención anual.
- Menú `Internal` en el binario de producción: overlay de debug del visor, forzar modo HID/Custom del grip, etc.

## Grips

- Dos grips: **Fjorden** (a través de `FjordenSDK`; el firmware se actualiza desde la app de Fjorden) y
  **Leica LUX Grip**, codename **"Kiki"**. Este último trae el firmware dentro de la app
  (`Firmware/1.0.3.bin`) y se actualiza por Bluetooth con MCUmgr (nRF Device Manager); requiere 20 % de batería.
- Dos modos de comandos: **HID** (el grip actúa como teclado Bluetooth) o **Custom** (GATT propio).
- Botones FN asignables: flash, peaking, grilla, histograma, nivel, lente siguiente/anterior,
  auto↔manual, cámara frontal/trasera, P↔A, temporizador. Palanca (Fjorden). Tiempo de apagado configurable.

## Diferencias en la v1.12.1 (build 247)

Muestra: `Leica_LUX_1.12.1_g9fahpbp.ipa`. **Misma procedencia**: descifrada, firma ad‑hoc y las mismas
inyecciones (`Tg_Sa1y0miii26.dylib` desbloquea RevenueCat, `StopReviews`, `zxPluginsInject`, `sideloadKeychainfix1/2`,
ElleKit). iOS mínimo 18.0, Xcode 26.4. Paquetes: `tyson-pipeline` 1.8.1→**1.15.1**, `tyson-looks` 1.13.4→**1.19.0**,
`tyson-gallery` 1.6.7→1.8.1, `leica-ui` pasa a versión semántica (0.5.5), aparecen **`tyson-lpc` 1.1.0** y un
bundle **`TysonML`**. Desaparece AppsFlyer de la lista de dependencias.

### Nuevo: super‑resolución de profundidad con ML (`TysonML`)

- Único modelo CoreML: **`FGSRBaseR1.mlmodelc`** (14,5 MB de pesos fp16, ≈7 M parámetros; PyTorch 2.5.1 →
  coremltools 8.3).
- Entradas: `depth_lr` (profundidad de baja resolución, gris fp16, 256×256 por defecto) y `guide` (imagen en gris,
  1024×1024 por defecto, hasta 4096). Salida: `depth_hr`. Factor ×4 (`upsample_bilinear` ×4 + red convolucional
  con `pixel_unshuffle`/`pixel_shuffle`).
- Es **super‑resolución de profundidad guiada por la imagen** ("FG SR" = *guided depth super‑resolution*, *inferido*):
  agranda el `AVDepthData` y lo alinea con los bordes reales de la foto. Explica la "mejor segmentación en
  modo Aperture" de la 1.11.0.
- Kernels Metal del bundle: `rescaleDepthMap`, `rescaleMonocularDepthMap`, `clipDepth`, `depthLimits`,
  `predDepthLimits`, `guideGrayscale`.
- La segmentación sigue siendo de Apple: el binario usa `AVSemanticSegmentationMatte` y `AVPortraitEffectsMatte`
  y detección de caras de Vision para elegir el foco.

### Nuevo: Leica Perspective Control (`tyson-lpc`)

- Clases `LPCDataProvider`, `LPCWarp`, `LPCHoleMask`, `LPCRectangle`, `LPCOverlay`, `LPCXMPWriter`, `CameraFunctionPerspectiveControl`.
- Usa **`CMMotionManager` y `_gravityVector`**: la corrección sale de la inclinación del teléfono al disparar,
  no de detectar líneas. Confirma la hipótesis de 01.
- **No destructivo**: escribe la corrección como XMP con un namespace propio
  `http://leica-camera.com/digital-shift-assistant/1.0/` (`xmpDSA`), y el warp se aplica al renderizar.
  `LPCHoleMask` *inferido*: máscara de los bordes vacíos tras el warp (para recortar).
- No disponible con cámara frontal, fuera del modo P, ni en RAW (strings `HUD.PerspectiveControlNotAvailable.*`).

### Looks y efectos

- Nuevo Look **Silver** (interno en las notas de TestFlight).
- **Filtros de color para monocromo**: `Leica_monochrome_{red,orange,yellow,green,blue}.data`, LUTs 3D **16³
  RGBA16F** (32 768 bytes) cuya salida es gris (R=G=B) → convierten color a B/N ponderando canales como un filtro físico.
  Shaders `applyTonesWithColorFilter[AndLutInterpolation]` con `colorFilterProfileTexture`: primero el filtro y después el LUT del Look.
- **Bloom**: `BloomExtractHighlights` → cadena de MIPs → `BloomApplyCombinedMIPs` / `BloomAddWeightedLevel` (`strength`).
  Técnica clásica de bloom por pirámide de MIPs.
- Bokeh: se reemplaza `jointBilateralUpsampling` por `jointBilateralUpsamplingFull` y `jointBilateralUpsamplingFrontBokeh`,
  y se agregan `depthLayerSubsampling` y `maxPoolingSubsampling` (render de capas a baja resolución + upsampling guiado).
- Sin cambios en lentes: mismas 15 carpetas PSF/LSP.

## Qué queda abierto

| Pregunta | Cómo cerrarla |
|---|---|
| Formato exacto de los `.data` de PSF | Más análisis de bytes o del código de `tyson-pipeline` (requiere leer el binario) |
| Cómo se usan juntos `secondaryLutTexture` / `lambdaLUTTexture` | Ídem |
| ¿Hay estimación de profundidad monocular (sin `AVDepthData`)? `rescaleMonocularDepthMap` lo sugiere, pero no hay modelo en el bundle | Strings/código o probar en una cámara sin profundidad |
| Cambios de 1.12 → 2.0.1 (Halation, PURE/CINE, galería compartida, McCurry) | Repetir el análisis con la IPA oficial actual |
| Tráfico real (endpoints de Leica Club, flags remotos) | Proxy en un iPhone con la app oficial |

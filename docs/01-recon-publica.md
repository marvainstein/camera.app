# 01 — Reconocimiento público de Leica LUX (iOS)

Fecha del relevamiento: 2026-10-19. Fuentes: App Store (API `itunes.apple.com/lookup` y página del listing),
leica-camera.com y prensa de lanzamiento (junio 2024). Todo lo que sigue es **observado en fuentes públicas**
salvo lo marcado como *hipótesis*.

## Identidad

| Campo | Valor |
|---|---|
| Nombre en tienda | Leica LUX - Pro Manual Camera |
| Bundle ID | `com.leica-camera.camera` |
| App Store ID | 6477182657 |
| Vendedor | Leica Camera AG (desarrollo "in-house") |
| Versión actual | 2.0.1 (2026-10-14) |
| Primera versión | 2024-06-05 |
| iOS mínimo | 26.0 — solo iPhone |
| Tamaño | ~425 MB (mucho para una app de cámara → modelos ML, LUTs y/o texturas pesadas) |
| Idiomas | EN, FR, DE, IT, JA, KO, PT, RU, ZH, ES |
| Rating | 4.85 (≈7.9K) |

## Modelo de negocio

- Gratis: modos Auto (P) y Prioridad de apertura (A), lente Summilux‑M 28 f/1.4, 5 Looks, guardado ProRAW.
- **LUX Pro**: USD 6.99/mes o 69.99/año (con trial). Desbloquea controles manuales (exposición, foco, WB),
  todos los Looks, todas las lentes, RAW sin procesar (Bayer DNG).
- "Lifetime PRO" incluido con el accesorio LUX Grip (desde 1.14.2) → hay un mecanismo de canje/entitlement
  ligado al hardware o a un código.

## Inventario de funcionalidades

### Captura
- Modos P / A / manual (S, ISO, WB, foco manual, compensación EV).
- Salida JPEG/HEIC con Look, Apple ProRAW, RAW Bayer "sin procesar" (Pro).
- **Looks sobre RAW** preservando el RAW original (1.11.0) → edición no destructiva (probablemente vía
  `PHAdjustmentData`; ver bug "metadata incorrecta tras revertir en Fotos" en 1.13.2).
- Relaciones de aspecto, grilla, histograma/overlay de altas luces ("highlight overlay").
- **Leica Perspective Control** (1.10.1): corrección de verticales con un toque.
  *Hipótesis*: igual que en las cámaras Leica, usa la inclinación del giroscopio (CoreMotion) para una
  homografía de keystone, no detección de líneas.
- Zoom / cambio de lente deslizando (1.11.0).

### Simulación de lentes
- Summilux‑M 28 f/1.4 ASPH, Summilux‑M 35 f/1.4, Noctilux‑M 50 f/1.2 ASPH, APO‑Telyt‑M 135 (solo modelos con tele).
- "Custom software engine" para bokeh en el dispositivo; 1.11.0 menciona "mejor **segmentación** en modo Aperture".
- *Hipótesis*: profundidad (`AVDepthData` / matte de retrato) + modelo de segmentación propio (CoreML) →
  render de bokeh en Metal con kernel por lente (forma de apertura, ojo de gato, viñeteo, aberraciones),
  más recorte de FOV sobre la cámara principal/tele para la focal equivalente.
- Bug 1.11.6: "falla la simulación tele en iPhone 17 Pro con iOS 26.3+" → depende de la cámara tele física.

### Looks y efectos
- Looks: Leica Classic, Contemporary, Black & White (Natural/High Contrast), Vivid, Eternal, Sepia/Blue
  (heredados de cámaras Leica), PURE y CINE (1.14.1), Artist Look Steve McCurry (1.15.0). ">15 looks".
- Filtros monocromo tipo filtro de color de B/N (1.12.1).
- Grano de película (mejorado 1.14.4), **Halation** (1.13.0, brillo cálido alrededor de luces),
  **Bloom** (1.12.1).
- "Compare Your Look" en Recompose (1.13.0) → hay un editor post‑captura ("Recompose").
- *Hipótesis*: cada Look = LUT 3D + curva tonal + parámetros (saturación, grano, viñeta); los efectos
  ópticos (halation/bloom) son pasadas Metal separadas.

### Integración con el sistema
- Widgets de pantalla de bloqueo (WidgetKit) y captura desde pantalla bloqueada (*hipótesis*:
  extensión `LockedCameraCapture`, iOS 18+). Widgets específicos de modo A para iPhone 17 Pro.
- Botones FN personalizables (mantener presionado para asignar) y **Quick Menu** personalizable (rediseñado en 2.0).
- Soporte **LUX Grip** (empuñadura con botón FN físico). *Hipótesis*: Bluetooth LE (CoreBluetooth) o
  accesorio MFi; también probable soporte de Camera Control del iPhone 16+ (`AVCaptureControl`).
- **Galería compartida con Leica FOTOS** (2.0) → App Group / contenedor compartido entre ambas apps.
- Íconos alternativos (2.0).
- Abrir en editor externo (2.0.1).

### Privacidad / SDKs (etiquetas de App Store)
- Datos usados para **tracking**: Identificadores y Datos de uso → hay al menos un SDK de atribución/marketing
  (*hipótesis*: Adjust, AppsFlyer o Firebase/Google).
- Analytics (User ID, Device ID, interacción) y diagnósticos (crash, performance) → SDK de crash reporting
  (*hipótesis*: Firebase Crashlytics o Sentry).
- "User ID" en funcionalidad → existe cuenta Leica (compartida con FOTOS, *hipótesis*).

## Historial de versiones relevante

| Versión | Fecha | Cambio |
|---|---|---|
| 2.0.0–2.0.1 | 2026‑10 | Quick Menu nuevo, galería compartida LUX+FOTOS con filmstrip, íconos alternativos |
| 1.15.0 | 2026‑09 | Artist Look Steve McCurry |
| 1.14.4 | 2026‑09 | Grano mejorado; fix EV inicial |
| 1.14.1–1.14.2 | 2026‑07 | Looks PURE y CINE; slider de Halation; Lifetime PRO por LUX Grip |
| 1.13.0 | 2026‑06 | Halation; Compare Your Look en Recompose |
| 1.12.x | 2026‑04/05 | Botones FN, filtros monocromo, Bloom, Quick Menu personalizable, FN del Grip |
| 1.11.0 | 2026‑02 | Looks sobre RAW, cambio de lente por swipe, mejor segmentación |
| 1.10.1 | 2025‑12 | Perspective Control; localización completa |
| 1.0 | 2024‑06 | Lanzamiento |

## Qué no se puede saber sin el binario/recursos

Formato real de los Looks (LUT, tamaño, espacio de color), qué modelos ML usa y para qué, nombres de los
shaders Metal, SDKs exactos, extensiones de app, entitlements (App Groups, Bluetooth, iCloud), backend y
endpoints. Eso es el objetivo de [02-plan-re.md](02-plan-re.md).

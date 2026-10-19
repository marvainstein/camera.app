# 04 — Arquitectura propuesta para la alternativa (borrador)

Basado en el comportamiento relevado en [01-recon-publica.md](01-recon-publica.md). Se ajusta cuando
tengamos los hallazgos de la Fase 1 ([02-plan-re.md](02-plan-re.md)). Todo con frameworks de Apple; sin
dependencias de terceros en el núcleo.

```
┌──────────── UI (SwiftUI) ─────────────┐
│ Visor · Quick Menu · FN · Paywall     │
│ Galería · Editor (Recompose)          │
└──────┬───────────────────────┬────────┘
       │                       │
┌──────▼───────┐      ┌────────▼─────────┐      ┌────────────────┐
│ CaptureCore  │─────▶│  RenderPipeline  │─────▶│  Library       │
│ AVFoundation │ RAW/ │  Metal/CoreImage │ HEIC │  PhotoKit +    │
│ + CoreMotion │ depth│  (looks, bokeh,  │ DNG  │  AdjustmentData│
└──────────────┘      │   grain, halation)│      └────────────────┘
                      └────────▲─────────┘
                               │
                      ┌────────┴─────────┐
                      │ Segmentation (ML)│
                      │ Vision / CoreML  │
                      └──────────────────┘
```

## Módulos

| Módulo | Responsabilidad | APIs clave |
|---|---|---|
| **CaptureCore** | Sesión, selección de cámara física, modos P/A/S/M, ISO/obturación/WB/foco manual, ProRAW y Bayer RAW, profundidad | `AVCaptureSession`, `AVCaptureDevice.setExposureModeCustom`, `setWhiteBalanceModeLocked(with:)`, `AVCapturePhotoOutput` (`isAppleProRAWEnabled`, `isDepthDataDeliveryEnabled`, `isPortraitEffectsMatteDeliveryEnabled`), `AVCaptureControl` (Camera Control) |
| **LensSim** | Focal equivalente (recorte + elección de cámara), bokeh por capas de profundidad convolucionando con la PSF de cada lente/apertura, viñeteo | Metal compute (FFT o convolución directa por capa); profundidad de `AVDepthData`; matte de `VNGeneratePersonSegmentationRequest` |
| **Looks** | Look = LUT 3D (33³ o 64³) + curva + parámetros de grano/halation/bloom/viñeta, descrito en JSON versionado | `CIColorCubeWithColorSpace` o kernel Metal propio; diseño de looks en DaVinci/Lightroom exportando `.cube` |
| **Effects** | Grano (dependiente de luminancia y resolución), halation (umbral de altas luces → blur rojo/naranja), bloom | Metal compute, `MPSImageGaussianBlur` |
| **Perspective** | Corrección de verticales con la inclinación del dispositivo (pitch) → homografía; fallback con Vision (`VNDetectHorizonRequest`/detección de líneas) | CoreMotion, `CIPerspectiveCorrection` |
| **Library** | Guardado con edición no destructiva (RAW original + `PHAdjustmentData` con el Look) y galería propia | PhotoKit, `PHContentEditingOutput` |
| **Editor** | Recomponer: cambiar Look/lente/recorte después de la toma, comparar antes/después | Reutiliza RenderPipeline sobre el RAW/profundidad guardados |
| **Extensions** | Widgets de pantalla bloqueada, captura desde pantalla bloqueada, Control Center | WidgetKit, `LockedCameraCapture`, `ControlWidget` |
| **Monetización** | Suscripción + lifetime | StoreKit 2 |

## Orden sugerido (MVP → completo)

1. CaptureCore con P/A y manual + guardado HEIC/ProRAW.
2. Looks con 3–5 LUTs propios + grano, aplicado en preview (tiempo real) y en la foto final.
3. Editor no destructivo con `PHAdjustmentData`.
4. LensSim: focales por recorte → bokeh con matte de persona → bokeh con mapa de profundidad completo.
5. Halation/bloom, perspectiva, widgets, Camera Control.
6. Paywall/StoreKit.

## Ajustes a partir de [03-hallazgos.md](03-hallazgos.md)

Lo que Leica hace (observado) y cómo lo resolvemos con material propio:

| Tema | Leica LUX | Nuestra decisión |
|---|---|---|
| Looks | LUT 3D 64³ RGBA16F como textura Metal, variantes sRGB y P3, mezcla entre dos LUTs (intensidad) | Mismo formato técnico (es estándar). LUTs **diseñados por nosotros** (Resolve → `.cube` → binario 64³ f16) |
| Grano | Modelo booleano estocástico + versión gaussiana | Implementar el paper de Newson et al. (2017), con versión gaussiana para el preview |
| Bokeh | Capas por profundidad + convolución con **PSF medida por lente/apertura**; gaussiano en preview | Igual en arquitectura. PSFs **propias**: sintéticas (forma de apertura, ojo de gato, aberración esférica, swirl) o medidas con lentes reales |
| Profundidad / segmentación | `AVDepthData` + mattes de Apple (`AVSemanticSegmentationMatte`, `AVPortraitEffectsMatte`); desde 1.11, super‑resolución de profundidad ×4 guiada por la imagen (CNN propia de ~7 M parámetros, CoreML) | Igual en arquitectura: entrenar nuestra propia red de *guided depth SR* con datasets públicos (p. ej. NYU‑v2, Middlebury) o empezar con joint bilateral upsampling, que no requiere ML |
| Perspectiva | Vector de gravedad de CoreMotion al disparar → warp no destructivo guardado en XMP (namespace propio) | Igual: CoreMotion + homografía; guardar los parámetros en nuestro propio namespace XMP |
| Bloom / filtros B/N | Pirámide de MIPs; filtros de color como LUT 16³ previo al Look | Técnicas estándar, implementarlas igual |
| Arquitectura de código | Paquetes SPM por dominio (core, pipeline, looks, gallery, ui) + swift-dependencies | Igual: es buena práctica y nos permite testear el pipeline aislado |
| Grip | BLE: HID o GATT propio, DFU por MCUmgr | Fase posterior; soportar primero Camera Control y botones de volumen |
| Monetización | RevenueCat, packs Core/Essential | StoreKit 2 directo o RevenueCat |

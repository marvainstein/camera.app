# camera.app

Estudio de Leica LUX (iOS) y app de cámara alternativa propia.

## Documentación

| Doc | Contenido |
|---|---|
| [docs/01-recon-publica.md](docs/01-recon-publica.md) | Todo lo que se sabe de fuentes públicas: features, versiones, precios, privacidad |
| [docs/02-plan-re.md](docs/02-plan-re.md) | Cómo obtener y analizar la IPA, observación en runtime, reglas clean room |
| [docs/03-hallazgos.md](docs/03-hallazgos.md) | Análisis de recursos de las IPA v1.8.5 y v1.12.1: arquitectura, SDKs, formato de Looks, pipeline de bokeh, grips |
| [docs/04-arquitectura-alternativa.md](docs/04-arquitectura-alternativa.md) | Borrador de arquitectura de la alternativa |

Herramienta: `scripts/inspect_ipa.sh App.ipa` inventaria una IPA sin ejecutar nada de su contenido.

Este repo no contiene ni debe contener material de Leica (IPAs, LUTs, modelos, assets).
`re-out/` está en `.gitignore` y la app no usa nada de ahí.

## App (esqueleto: pasos 1 y 2 de docs/04)

SwiftUI, iOS 18+, sin dependencias de terceros.

```
CameraApp.xcworkspace      ← abrir esto (proyecto + paquetes, corre todos los tests)
CameraApp.xcodeproj        app: visor, Looks, controles P/A y manuales
App/                       fuentes de la app (carpeta sincronizada con Xcode)
Packages/CaptureCore/      AVFoundation: sesión, P/A, ISO/obturación/EV/WB manual,
                           captura HEIC + ProRAW, guardado en Fotos (PhotoKit)
Packages/Looks/            Metal: LUT 3D 64³ RGBA16F + intensidad + grano gaussiano;
                           mismo pipeline para el preview y la foto final
scripts/make_luts.py       genera los LUTs de ejemplo (fórmulas propias) y convierte .cube
scripts/test.sh            corre todos los tests en el simulador
```

### Requisitos

- Xcode 16 o posterior (probado con Xcode 26.5 en un Mac Intel) y un simulador de iPhone.
- Python 3 (solo stdlib) si querés regenerar los LUTs.

### Correr en el simulador

1. `open CameraApp.xcworkspace`, elegir el scheme **CameraApp** y un iPhone simulado, ⌘R.
2. El simulador no tiene cámara: la app muestra un **patrón de prueba** con el Look aplicado, así
   se pueden probar Looks, intensidad, grano y los controles manuales. El disparador queda
   deshabilitado.

Desde la terminal:

```bash
xcodebuild -workspace CameraApp.xcworkspace -scheme CameraApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build/DerivedData build
```

### Correr en un iPhone

En el target CameraApp → Signing & Capabilities, elegir tu Team (y cambiar el bundle id
`com.marvainstein.cameraapp` si hace falta). La app pide permiso de cámara y de "agregar a Fotos".
ProRAW solo se habilita en modelos Pro.

### Tests

```bash
scripts/test.sh
```

Corre en el simulador los tests de ambos paquetes (test plan `CameraApp.xctestplan`). También se
pueden correr en macOS, más rápido:

```bash
swift test --package-path Packages/Looks
```

```bash
swift test --package-path Packages/CaptureCore
```

Qué se prueba:

- **Looks**: LUT identidad ⇒ salida idéntica a la entrada (8 bits exacto y < ½ nivel en float16);
  intensidad 0 y "sin LUT" no tocan la imagen; el B/N es neutro; la GPU coincide con una
  referencia trilineal en CPU (±1 nivel); el grano es determinista por semilla y no cambia el
  brillo medio; formato `.lut` (ida y vuelta, cabecera inválida, archivo truncado); aspect fill.
- **CaptureCore**: resolución P/A/manual a exposición automática o custom, recorte a los límites
  del dispositivo, paradas de ISO/obturación, ganancias de balance de blancos.

### Cómo funciona

- **Preview**: `AVCaptureVideoDataOutput` (BGRA, rotado a vertical) → `CVMetalTextureCache` →
  `LookRenderer` (vertex + fragment shader, un triángulo de pantalla completa) → `MTKView`.
  El grano usa una semilla distinta por frame.
- **Look**: el color de entrada (valores codificados, 0…1) se usa como coordenada en una
  textura 3D 64³ `.rgba16Float` con filtrado lineal, apuntando al centro de los texeles
  (`c·(N−1)/N + 0.5/N`); el resultado se mezcla con la entrada según la intensidad.
- **Grano**: ruido gaussiano (hash PCG + Box-Muller) por celda; el tamaño de celda es relativo al
  lado corto de la imagen, así el grano se ve igual en el preview y en la foto. Más fuerte en
  medios tonos.
- **Foto**: el HEIC procesado se decodifica, pasa por el mismo `LookRenderer` y se vuelve a
  codificar en HEIC conservando los metadatos. Con ProRAW, el DNG se guarda intacto como
  recurso alternativo del mismo asset en Fotos.
- **Modos**: P = exposición automática + EV. A = apertura **simulada** (el iPhone tiene apertura
  fija): por ahora solo se guarda en `CaptureSettings` para LensSim (paso 4). Fijar ISO u
  obturación pasa a exposición custom; el otro valor toma el actual de la cámara.
- Los shaders se compilan en runtime desde Swift (`LookShaders.swift`) para que el paquete
  funcione igual con `swift test` en macOS que en iOS.

### LUTs

Los Looks incluidos (`Packages/Looks/Sources/Looks/Resources/LUTs/`) salen de fórmulas propias en
`scripts/make_luts.py`: **Natural** (identidad), **B/N Neutro** (luminancia Rec.709 + curva S
suave) y **Cálido** (balance cálido en luz lineal, sombras levantadas, +8 % saturación).
`looks.json` es el manifiesto versionado (id, nombre, archivo, grano sugerido).

```bash
python3 scripts/make_luts.py
```

Para sumar un Look diseñado en Resolve/Lightroom: exportar un `.cube` 3D, convertirlo y
agregarlo a `LOOKS`/`looks.json`:

```bash
python3 scripts/make_luts.py convert mi-look.cube Packages/Looks/Sources/Looks/Resources/LUTs/mi-look.lut
```

Formato `.lut`: cabecera de 16 bytes (`LAIKALUT`, versión u32 = 1, tamaño u32 = 64) + 64³ texeles
RGBA float16 little-endian, R variando más rápido (mismo layout que la textura Metal 3D).

### Pendiente / limitaciones conocidas

- El LUT se aplica sobre valores codificados en el espacio de color de la fuente (sRGB/P3 del
  preview o del HEIC); todavía no hay variantes por espacio de color.
- La foto con Look se procesa en 8 bits (pierde el rango extra del HEIC de 10 bits).
- Edición no destructiva con `PHAdjustmentData` (paso 3), LensSim/bokeh (paso 4) y el resto de
  docs/04 todavía no están.
- Captura en un iPhone real no verificada todavía (solo simulador).

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
                           mismo pipeline para el preview y la foto final; recetas de
                           película que generan su LUT en el dispositivo
scripts/make_luts.py       catálogo de Looks: recetas y LUTs propios, importa .cube
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

Compila la app y corre en el simulador (el iPhone del runtime de iOS más nuevo, o el que pases como
argumento) los tests de ambos paquetes (test plan `CameraApp.xctestplan`). Los tests de GPU se
saltean si la máquina no tiene Metal. También se pueden correr en macOS, más rápido:

```bash
swift test --package-path Packages/Looks
```

```bash
swift test --package-path Packages/CaptureCore
```

Qué se prueba:

- **Looks**: LUT identidad ⇒ salida idéntica a la entrada (8 bits exacto y < ½ nivel en float16);
  el LUT que genera Swift para cada receta coincide con la referencia 17³ de Python (±1/1024);
  caché en disco de los LUTs generados;
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

`Packages/Looks/Sources/Looks/Resources/LUTs/looks.json` es el catálogo (id, nombre, grano
sugerido y de dónde sale el LUT). La app muestra los Looks en ese orden. Cada Look tiene una de dos
cosas:

- `"recipe": {…}`: **receta de película**, los parámetros de `film_look()` (calidez, tinte, brillo,
  altas_luces, contraste, negros, blancos, verdes_oliva, verdes_apagados, azules_apagados,
  rojos_amarillos, saturacion, sombras_frias, luces_amarillas, mono; tinte, brillo y mono son
  opcionales). La app genera el LUT 64³ en el dispositivo (`FilmRecipe.swift`, port 1:1 del script
  en `Double`, en paralelo por planos) la primera vez que se elige el Look, y lo cachea en memoria y
  en `Library/Caches/Looks/` con clave id + hash de la receta + versión del generador. Unos 25 ms
  en un Mac en release. Son: **Dorado 200**, **Retrato 400**, **Ámbar 800**, **Negativo Diario**,
  **Diapositiva**, **Plata 400** y **Cine Verde**.
- `"lut": "archivo.lut"`: LUT precalculado en el bundle. Los de fórmula fija de
  `scripts/make_luts.py` (**Natural** = identidad, **B/N Neutro** = luminancia Rec.709 + curva S
  suave, **Cálido** = balance cálido en luz lineal, sombras levantadas, +8 % saturación) y los
  `.cube` importados.

La app carga cada LUT recién cuando se elige el Look, fuera del main actor; hasta que está listo el
preview sigue con el anterior, y la foto se hornea con el LUT si ya está cargado.

`generate` reescribe las recetas y los `.lut` de fórmula fija en el catálogo (respeta los
importados):

```bash
python3 scripts/make_luts.py generate
```

Si se cambia `film_look()`, hay que cambiar igual `FilmRecipe.apply`, subir
`FilmRecipe.generatorVersion` (invalida los cachés) y regenerar las referencias de los tests
(17³, en `Packages/Looks/Tests/LooksTests/Resources/`):

```bash
python3 scripts/make_luts.py export-reference
```

Para comparar a mano, `export-lut` escribe el `.lut` 64³ de cualquier Look propio (o de todos) sin
tocar el catálogo, por defecto en `build/luts/`:

```bash
python3 scripts/make_luts.py export-lut dorado-200 plata-400
```

**Importar un LUT** (`.cube` 3D de cualquier tamaño, p. ej. 17/33/65, con o sin `DOMAIN_MIN/MAX`):
se remuestrea a 64³, se adapta al espacio de entrada de la app y se agrega o actualiza en el
catálogo.

```bash
python3 scripts/make_luts.py add mi-look.cube --id mi-look --name "Mi Look" --grain 0.2 --input rec709
```

- `--input srgb` (por defecto): el LUT espera valores sRGB, igual que la app.
- `--input rec709`: el LUT se diseñó para Rec.709 gamma 2.4 (lo típico en Resolve). Se convierten
  la entrada y la salida para que se vea como en el programa de origen.
- Todavía no se soportan LUTs que esperan log (Apple Log, S-Log3…) ni `.cube` con shaper 1D.
  El script los rechaza con un mensaje.

```bash
python3 scripts/make_luts.py list
```

```bash
python3 scripts/make_luts.py remove mi-look
```

Solo usar LUTs propios o con licencia que permita distribuirlos dentro de la app.

Formato `.lut`: cabecera de 16 bytes (`LAIKALUT`, versión u32 = 1, tamaño u32 = 64) + 64³ texeles
RGBA float16 little-endian, R variando más rápido (mismo layout que la textura Metal 3D).

### Pendiente / limitaciones conocidas

- El LUT se aplica sobre valores codificados en el espacio de color de la fuente (sRGB/P3 del
  preview o del HEIC); todavía no hay variantes por espacio de color.
- La foto con Look se procesa en 8 bits (pierde el rango extra del HEIC de 10 bits).
- Edición no destructiva con `PHAdjustmentData` (paso 3), LensSim/bokeh (paso 4) y el resto de
  docs/04 todavía no están.
- Captura en un iPhone real no verificada todavía (solo simulador).

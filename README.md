# camera.app

Estudio de Leica LUX (iOS) y app de cámara alternativa propia.

Para sumarse al proyecto, ver [CONTRIBUTING.md](CONTRIBUTING.md).

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
CameraApp.xcodeproj        app: visor, Looks, editor de recetas, controles P/A y manuales
App/                       fuentes de la app (carpeta sincronizada con Xcode)
Packages/CaptureCore/      AVFoundation: sesión, P/A, ISO/obturación/EV/WB manual,
                           captura HEIC + ProRAW, guardado en Fotos (PhotoKit)
Packages/Looks/            Metal: LUT 3D 64³ RGBA16F + intensidad + nitidez/claridad/viñeteo + grano;
                           mismo pipeline para el preview y la foto final; recetas de
                           película que generan su LUT en el dispositivo; recetas propias
scripts/make_luts.py       catálogo de Looks: recetas y LUTs propios, importa .cube
scripts/test.sh            corre todos los tests en el simulador
tools/laboratorio/         Laboratorio de recetas: el motor de Looks en el navegador
```

### Requisitos

- Xcode 16 o posterior (probado con Xcode 26.5 en un Mac Intel) y un simulador de iPhone.
- Python 3 (solo stdlib) si querés regenerar los LUTs.

### Correr en el simulador

1. `open CameraApp.xcworkspace`, elegir el scheme **CameraApp** y un iPhone simulado, ⌘R.
2. El simulador no tiene cámara: la app muestra un **patrón de prueba** con el Look aplicado, así
   se pueden probar Looks, intensidad, grano y los controles manuales.
3. Para probar con una **foto propia** (en el simulador o en el iPhone): el botón de foto de la
   barra superior abre la fototeca y la foto pasa a ocupar el visor, con el Look, el editor y los
   efectos en vivo. El disparador guarda una copia con el Look en Fotos (la original no se toca);
   el botón de cámara vuelve al visor. Al simulador se le agregan fotos arrastrándolas a su ventana.

Desde la terminal:

```bash
xcodebuild -workspace CameraApp.xcworkspace -scheme CameraApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build/DerivedData build
```

### Correr en un iPhone

En el target CameraApp → Signing & Capabilities, elegir tu Team (y cambiar el bundle id
`com.martinyernesto.cameraapp` si hace falta). La app pide permiso de cámara y de "agregar a Fotos".
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
  brillo medio; formato `.lut` (ida y vuelta, cabecera inválida, archivo truncado); aspect fill;
  la receta neutra es la identidad; los rangos del editor cubren todas las recetas incluidas;
  recetas propias (guardar/leer, compartir e importar texto, valores fuera de rango acotados);
  efectos: el viñeteo oscurece solo las esquinas, la nitidez y la claridad no tocan zonas planas
  y suben el contraste en los bordes.
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
- **Halation y bloom**: al reducir la fuente se mide cuánto de cada zona es luz casi quemada; un pase
  aparte lo difumina (gaussiano) y el shader lo suma en modo trama, blanco cálido (bloom) o rojo
  anaranjado (halation, el halo de la película alrededor de las luces fuertes).
- **Efectos** (en el mismo shader, solo si el Look los usa): **nitidez** compara cada píxel con sus
  4 vecinos de la fuente; **claridad** lo compara con una versión de la fuente reducida a 48 px de
  lado corto (un pase previo que promedia 8×8 muestras por píxel), pesando más los medios tonos;
  ambos actúan sobre la luminancia, antes del LUT. El **viñeteo** va después del LUT, relativo al
  cuadro de salida. Como el grano, todo es relativo al tamaño de la imagen.
- Los shaders se compilan en runtime desde Swift (`LookShaders.swift`) para que el paquete
  funcione igual con `swift test` en macOS que en iOS.

### Looks (todo es receta)

`Packages/Looks/Sources/Looks/Resources/LUTs/looks.json` es el catálogo (id, nombre, grano
sugerido, receta y efectos), en el orden en que lo muestra la app. Son 13, pocos y bien distintos:

- **Color:** Natural (la receta neutra), Dorado 200, Retrato 400, Clásico, Documental,
  Contemporáneo, Puro, Cine y Verde Azulado.
- **Estilizado:** Blanqueo.
- **B/N:** Plata 400, B/N Alto Contraste y Sepia. Los filtros de color para B/N son un slider de
  cualquier receta B/N.

Los que se parecían a otros quedaron en `ARCHIVO` de `make_luts.py` (fuera de la app, por si alguno
vuelve).

Cada Look es una **receta**: `"recipe": {…}`, los parámetros de `film_look()` (calidez, tinte,
brillo, altas_luces, contraste, negros, blancos, verdes_oliva, verdes_apagados, azules_apagados,
rojos_amarillos, saturacion, sombras_frias, luces_amarillas, mono; tinte, brillo y mono son
opcionales; también lo son el **filtro de color para B/N**, `filtro` 0…1 y `filtro_tono` en grados,
y el **virado partido**, `virado_sombras`/`virado_luces` 0…2 con su `_tono` en grados). La app
genera el LUT 64³ en el dispositivo (`FilmRecipe.swift`, port 1:1 del script en `Double`, en
paralelo por planos) la primera vez que se elige el Look, y lo cachea en memoria y en
`Library/Caches/Looks/` con clave id + LUT base + hash de la receta + versión del generador.

Un Look puede tener además un **LUT base** (`"lut": "archivo.lut"`): la receta se aplica sobre su
salida (con la receta neutra queda igual). Así entran los `.cube` que importa el usuario.

Y `"effects": {"nitidez": …, "claridad": …, "vineteo": …, "halation": …, "bloom": …}` (los que faltan
valen 0): lo que no entra en un LUT (ver `EFFECTS` en `make_luts.py`).

En la app (varita o mantener apretado un Look):
- **Editar** cualquier Look, incluidos los de la app: el cambio lo reemplaza y queda
  **Restaurar original**. **Duplicar y editar** crea otro.
- **Importar LUT (.cube)…**: el `.cube` (3D, cualquier tamaño, con o sin `DOMAIN_MIN/MAX`, para
  entrada sRGB) se remuestrea a 64³ y queda como base de una receta nueva: se retoca con los mismos
  sliders, grano y efectos. Los LUT con shaper 1D o entrada log todavía no se soportan.

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

### Formato y encuadre

- **Formato** (menú de la barra superior): RAW + JPG por defecto; también RAW + HEIC, JPG, HEIC o
  solo RAW. El RAW es Apple ProRAW en los iPhone Pro y el RAW del sensor (Bayer, sin el procesado de
  Apple) en los demás; en un iPhone sin RAW se usa el mismo formato sin RAW. Con RAW + JPG se guardan
  dos fotos separadas en Fotos: el JPG con el Look y el DNG intacto.
- **Encuadre** (como el modo crop de las compactas): una focal más larga que la del lente (28, 35,
  50, 75 mm, recortando al centro) y un formato (4:3, 3:2, 1:1, 16:9, que sigue la orientación de la
  foto). El visor muestra el cuadro entero con el marco del recorte y lo de afuera oscurecido; la
  foto procesada se guarda recortada (el viñeteo y el grano se miden sobre el recorte) y el RAW
  entero, para poder reencuadrar. La focal del lente sale de su campo de visión
  (`CameraCapabilities.equivalentFocalLength`) o, en una foto de la fototeca, de su EXIF.

### Recetas propias (editor)

El botón de la varita, a la izquierda de los Looks, abre el menú de recetas: **Receta nueva**
(arranca de la receta neutra), **Copiar y editar** un Look incluido o **Editar** una receta propia,
**Compartir receta** y **Pegar receta**. Lo mismo está en el menú contextual (mantener apretado) de
cada Look.

- El editor tiene un slider por parámetro de la receta (agrupados en Tono, Color y Virado), B/N,
  grano, nitidez, claridad y viñeteo. Tocar el valor lo vuelve a neutro. Los rangos están en
  `FilmRecipe.parameters` (`RecipeParameters.swift`).
- Se ve en vivo: el editor es un panel abajo y la imagen entera queda arriba (sin recortar). Con
  cada cambio se genera un LUT 25³ (milisegundos) y, si los sliders quedan quietos 300 ms, el de 64³.
- **Comparar** (botón de la barra superior): una línea divide la imagen en antes (izquierda, sin
  Look ni efectos) y después; se mueve arrastrando.
- Las recetas propias se guardan en `Application Support/Looks/user-looks.json`, con el mismo
  formato de entrada que `looks.json` (se pueden pasar al catálogo tal cual). Aparecen después de
  los incluidos, con un iconito.
- **Compartir** produce un JSON corto (`"formato": "camera.app/receta"`, nombre, receta, grano,
  efectos), como se comparten las recetas Ricoh por mensaje o en un foro. **Pegar** lo busca en el
  texto copiado (puede venir con texto alrededor; también acepta una entrada de `looks.json`) y
  acota cada valor al rango del editor.

### Laboratorio de recetas (navegador)

`tools/laboratorio/index.html` es un visor para armar recetas mirando el resultado, sin Xcode:
abrirlo en el navegador (doble clic). Tiene el mismo motor de color que la app: `motor.js` es el
port de `film_look()` y de los Looks de fórmula fija, y el shader WebGL hace lo mismo que
`LookShaders.swift` (nitidez, claridad, LUT, viñeteo, grano) en el mismo orden.

- Imagen: escenas sintéticas (atardecer, carta de color, el patrón de prueba de la app) o una foto
  propia (subir, arrastrar o pegar).
- Comparar antes/después arrastrando la línea, intensidad, todos los sliders del editor de la app.
- Guardar, copiar y pegar recetas con el mismo texto que la app (`LookShare`): una receta armada
  acá se pega en el iPhone con «Pegar receta», y al revés.
- `catalogo.js` lo genera `make_luts.py generate` desde `looks.json`; no editarlo a mano.

`node tools/laboratorio/verificar.js` compara el motor JS con las referencias de Python (las
mismas de los tests de Swift) y con los `.lut` de fórmula fija: la diferencia máxima es el
redondeo de float16.

### Pendiente / limitaciones conocidas

- El LUT se aplica sobre valores codificados en el espacio de color de la fuente (sRGB/P3 del
  preview o del HEIC); todavía no hay variantes por espacio de color.
- La foto con Look se procesa en 8 bits (pierde el rango extra del HEIC de 10 bits).
- Edición no destructiva con `PHAdjustmentData` (paso 3), LensSim/bokeh (paso 4) y el resto de
  docs/04 todavía no están.
- Captura en un iPhone real no verificada todavía (solo simulador).
- Halation y bloom (resto de Effects en docs/04) todavía no están.

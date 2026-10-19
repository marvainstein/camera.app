# 02 — Plan de ingeniería inversa

Objetivo: entender *qué hace* Leica LUX y *cómo está armada* lo suficiente para diseñar una alternativa
propia. No buscamos copiar código, LUTs, modelos ni assets de Leica (ver "Reglas" abajo).

## Fase 1 — Recursos de la IPA (estático, sin descifrar)

Una IPA de App Store viene con los ejecutables Mach-O cifrados con FairPlay, pero **todo lo demás está en
claro**: `Info.plist`, entitlements, extensiones, frameworks embebidos (nombres y versiones), modelos
CoreML compilados, `.metallib` (nombres de kernels), catálogos de assets, strings localizados y cualquier
archivo de datos (LUTs, JSON de configuración). Con eso se responde la mayor parte de las hipótesis de
[01-recon-publica.md](01-recon-publica.md).

### Cómo obtener la IPA (en una Mac Intel)

Hace falta que **vos** inicies sesión con tu Apple ID; eso no lo hago yo.

Opción A — `ipatool` (CLI open source):

```bash
brew install ipatool
```

```bash
ipatool auth login --email TU_APPLE_ID
```

```bash
ipatool purchase --bundle-identifier com.leica-camera.camera
```

```bash
ipatool download --bundle-identifier com.leica-camera.camera --output ~/re-inputs/LeicaLUX.ipa
```

Opción B — Apple Configurator 2 (herramienta oficial de Apple, Mac App Store) con el iPhone por USB:
*Agregar → Apps → Leica LUX*; mientras pregunta si reemplazar, la IPA queda en
`~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Assets/TemporaryItems/MobileApps/`.
Copiarla antes de cerrar el diálogo.

### Analizar

```bash
scripts/inspect_ipa.sh ~/re-inputs/LeicaLUX.ipa
```

Genera `re-out/<ipa>/0X-*.txt` (ignorado por git). De ahí destilamos hallazgos a `docs/03-hallazgos.md`.

Preguntas que esta fase cierra:

| Pregunta | Dónde mirar |
|---|---|
| ¿Qué SDKs (analytics, atribución, compras, crash)? | `02-frameworks-extensions.txt`, `01-app.txt` (dylibs) |
| ¿Qué extensiones (widgets, LockedCameraCapture, share)? | `02-frameworks-extensions.txt` |
| ¿App Groups compartidos con FOTOS, Bluetooth para el Grip, iCloud? | entitlements + `UIBackgroundModes` + `NS*UsageDescription` |
| ¿Formato de los Looks? | `03-recursos.txt` (LUTs, JSON, PNG de 512×512 = HALD/LUT) |
| ¿Qué modelos ML y para qué? | `.mlmodelc/metadata.json` (inputs/outputs, autor, tamaño) |
| ¿Cómo está armado el pipeline de render? | `04-metal.txt` (nombres de kernels: bokeh, halation, grain…) |
| Inventario completo de UI/features | `05-strings-ui.txt` |
| Backend | `07-urls.txt` |

## Fase 2 — Observación en runtime (en tu iPhone)

Sin modificar la app:

1. **Grabación de pantalla** de cada flujo (onboarding, paywall, modos, Quick Menu, Recompose, galería) →
   mapa de pantallas y estados.
2. **Fotos de salida**: capturar la misma escena con cada Look y lente; leer EXIF/MakerNotes/XMP
   (`exiftool`) para ver qué metadatos escribe (nombre de Look, lente simulada, `PHAdjustmentData`).
3. **Caracterización de color**: fotografiar una carta de color (o una pantalla calibrada con un patrón)
   con Look "Standard" vs cada Look → sirve para medir el *comportamiento* tonal y diseñar Looks propios
   que apunten a una estética similar sin extraer los de Leica.
4. **Tráfico de red** (opcional): proxy (mitmproxy/Proxyman) en tu propio iPhone para ver analytics,
   validación de suscripción, descarga remota de Looks. Puede haber certificate pinning; en ese caso
   lo dejamos ahí.

## Fase 3 — Binario (solo si hace falta)

Para leer código hace falta un binario **descifrado**, lo que implica un iPhone con jailbreak o
una Mac Apple Silicon y saltear FairPlay. Eso es eludir una medida técnica de protección (DMCA §1201 en EE.UU.,
art. 6 de la Directiva 2001/29 en la UE) y probablemente viola los términos de Leica. **No es necesario
para construir una alternativa** y no lo recomiendo; si se decide hacerlo, consultarlo antes con un abogado.

## Reglas (clean room)

- Este repo guarda **descripciones de comportamiento**, no material de Leica: nada de IPAs, LUTs, modelos,
  shaders, imágenes ni textos copiados (`.gitignore` ya excluye `*.ipa` y `re-out/`).
- Quien implemente la alternativa trabaja desde las especificaciones de `docs/`, no desde los recursos extraídos.
- No usar marcas de Leica (Leica, Summilux, Noctilux, nombres de Looks) en el producto.

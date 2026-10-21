# Cómo colaborar

Guía corta para sumarse al proyecto. El detalle técnico está en el [README](README.md) y la
arquitectura en [docs/04-arquitectura-alternativa.md](docs/04-arquitectura-alternativa.md).

## Ramas y PRs

Todo lo de la app está en `main`. Para un cambio nuevo: rama propia desde `main`, commits chicos y
PR contra `main`. No reescribir historia en ramas de otros (nada de `rebase` ni `push --force`);
para traer cambios, `git merge`.

Antes de mergear un cambio en Swift, correr `scripts/test.sh` en un Mac (o ⌘U en Xcode): las
sesiones de Claude en la nube no tienen Xcode y no pueden compilar.

## Primeros pasos (Mac con Xcode)

```bash
git clone https://github.com/marvainstein/camera.app.git camera-app
cd camera-app
scripts/test.sh
```

Ojo con el nombre de la carpeta: si queda `camera.app`, macOS la trata como una aplicación (el
Finder la muestra "dañada" y no la abre). Clonar en `camera-app`, o renombrarla y en GitHub Desktop
usar **Locate…** para apuntar a la carpeta nueva.

`scripts/test.sh` compila la app y corre los tests de los dos paquetes en el simulador. Si falla,
pegá la salida en el PR o en un issue. Lo mismo corre solo en GitHub Actions en cada PR (check
**Tests**).

**TestFlight:** el dueño sube los builds a mano, desde Xcode (Product → Archive → Distribute) o con
el botón **Actions → Subir a TestFlight → Run workflow**, que usa la clave de App Store Connect
guardada en los secretos del repo.

Para ver la app: `open CameraApp.xcworkspace`, scheme **CameraApp**, un iPhone simulado y ⌘R. El
simulador no tiene cámara: muestra un patrón de prueba con el Look aplicado. La varita, a la
izquierda de los Looks, abre el menú de recetas.

En un iPhone real: target CameraApp → Signing & Capabilities → elegir tu Team (y cambiar el bundle
id si Xcode lo pide).

## Sin Xcode: el Laboratorio

`tools/laboratorio/index.html` se abre con doble clic en cualquier navegador. Tiene el mismo motor
de color que la app y sirve para armar recetas mirando el resultado. Las recetas se copian como
texto y se pegan en la app con «Pegar receta» (y al revés).

Si se toca la fórmula de color, hay que cambiarla en los tres lugares y verificar:

- `scripts/make_luts.py` (`film_look`)
- `Packages/Looks/Sources/Looks/FilmRecipe.swift`
- `tools/laboratorio/motor.js`

```bash
python3 scripts/make_luts.py export-reference   # referencias para los tests de Swift
python3 scripts/make_luts.py generate           # looks.json y tools/laboratorio/catalogo.js
node tools/laboratorio/verificar.js             # el motor JS contra las referencias
```

## Con Claude Code

Cada uno puede abrir su propia sesión sobre este repo (claude.ai/code con su cuenta, conectando
GitHub y eligiendo `marvainstein/camera.app`). Conviene apuntarlo a este archivo y pedirle que
trabaje en una rama propia desde `main`. Las sesiones no comparten memoria: lo que importa tiene
que quedar en el repo, los PRs o los issues.

## Reglas del repo

- No subir material de Leica (IPAs, LUTs, modelos, assets). `re-out/` está en `.gitignore`.
- LUTs importados: solo propios o con licencia que permita distribuirlos en la app.
- Sin dependencias de terceros en la app.

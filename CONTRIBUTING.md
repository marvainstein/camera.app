# Cómo colaborar

Guía corta para sumarse al proyecto. El detalle técnico está en el [README](README.md) y la
arquitectura en [docs/04-arquitectura-alternativa.md](docs/04-arquitectura-alternativa.md).

## Ramas y PRs

| Rama | Qué tiene |
|---|---|
| `app/esqueleto-ios` | Base de la app: captura, Looks, visor. Los PRs apuntan acá. |
| `claude/looks-recetas-json-345575` | PR #2: los Looks de película como recetas (LUT generado en el dispositivo). Probado en el simulador. |
| `claude/looks-recetas-json-345575-sne4w3` | PR #3, encima del #2: editor de recetas, recetas propias, efectos (nitidez, claridad, viñeteo) y el Laboratorio web. **Sin compilar todavía.** |

Para un cambio nuevo: rama propia desde la que corresponda, commits chicos y PR contra esa rama.
No reescribir historia en ramas de otros (nada de `rebase` ni `push --force`); para traer cambios,
`git merge`.

## Primeros pasos (Mac con Xcode)

```bash
git clone https://github.com/marvainstein/camera.app.git
cd camera.app
git checkout claude/looks-recetas-json-345575-sne4w3
scripts/test.sh
```

`scripts/test.sh` compila la app y corre los tests de los dos paquetes en el simulador. Si falla,
pegá la salida en el PR #3 o en el issue de verificación.

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
GitHub y eligiendo `marvainstein/camera.app`). Conviene decirle en qué rama trabajar y apuntarlo a
este archivo. Las sesiones no comparten memoria: lo que importa tiene que quedar en el repo, los
PRs o los issues.

## Reglas del repo

- No subir material de Leica (IPAs, LUTs, modelos, assets). `re-out/` está en `.gitignore`.
- LUTs importados: solo propios o con licencia que permita distribuirlos en la app.
- Sin dependencias de terceros en la app.

# camera.app — notas para Claude

Lo que toda sesión de Claude Code sobre este repo tiene que saber de entrada. El detalle está en
[README.md](README.md) y [CONTRIBUTING.md](CONTRIBUTING.md).

## Personas y cuentas

- El dueño del repo (marvainstein) tiene **cuenta paga de Apple Developer Program**: para
  compartir builds se usa TestFlight (no hace falta proponer alternativas para cuentas gratis).
  Bundle ID de la app: `com.martinyernesto.cameraapp`; Team ID `5QX883QN6B` (fijo en el proyecto,
  así elegir el Team en Xcode no deja cambios locales que traben el Pull).
- Hay un colaborador con su propia sesión de Claude Code. Lo compartido vive en el repo, los PRs y
  los issues: las sesiones no comparten memoria.
- Se trabaja en castellano rioplatense (voseo), también en commits, PRs y comentarios del código.

## Cómo se trabaja

- Las sesiones en la nube **no tienen Xcode**: el Swift no se puede compilar ahí. Validar lo que se
  pueda (Python, `node tools/laboratorio/verificar.js`, el Laboratorio en Chromium headless) y pedir
  que se corra `scripts/test.sh` o ⌘U en el Mac antes de mergear un cambio en Swift.
- Los errores de compilación llegan pegados desde Xcode: corregirlos en la misma rama del PR.
- Expresiones largas con ternarios o SIMD sin tipos explícitos hacen que el compilador no llegue
  a tiempo ("unable to type-check this expression"): partirlas en líneas con tipos.
- PRs contra `main`. Con los tests en verde y el OK del dueño, se mergea.
- La carpeta local del clon se llama `camera-app`, no `camera.app` (macOS toma `.app` como una app).

## Reglas del producto

- **Clean room**: nada de material de Leica (IPAs, LUTs, `.cube` extraídos, mediciones de sus
  LUTs, nombres de sus Looks). Los Looks se diseñan desde la referencia fotográfica (película,
  papel, proceso) con valores propios. Ver `docs/02-plan-re.md`.
- Todo Look es una receta (`looks.json`, `scripts/make_luts.py`); la fórmula de color existe en
  tres copias que tienen que coincidir: `make_luts.py`, `FilmRecipe.swift` y
  `tools/laboratorio/motor.js`.
- Sin dependencias de terceros en la app.

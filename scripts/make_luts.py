#!/usr/bin/env python3
"""Catálogo de LUTs del paquete Looks: genera los propios e importa LUTs .cube.

Uso:
  scripts/make_luts.py generate
      Regenera los Looks propios (fórmulas de este archivo). Respeta los importados.
  scripts/make_luts.py add ARCHIVO.cube --id ID --name "Nombre" [--grain 0.2] [--input srgb|rec709]
      Importa un LUT 3D .cube (cualquier tamaño, con DOMAIN_MIN/MAX), lo remuestrea a 64³,
      lo adapta al espacio de entrada de la app y lo agrega/actualiza en looks.json.
  scripts/make_luts.py remove ID
  scripts/make_luts.py list
  scripts/make_luts.py convert ARCHIVO.cube SALIDA.lut [--input ...]
      Solo convierte, sin tocar el catálogo.

--input dice qué codificación espera el LUT de origen. La app le entrega valores sRGB (preview y
HEIC); con "rec709" (gamma 2.4, típico de Resolve) se convierte entrada y salida para que el
Look se vea como en el programa donde se diseñó. LUTs que esperan log (Apple Log, S-Log3…) o
que tienen shaper 1D todavía no están soportados.

Formato .lut (propio): cabecera de 16 bytes = b"LAIKALUT" + uint32 LE versión (1)
+ uint32 LE tamaño N (64), seguida de N³ texeles RGBA float16 little-endian con
R variando más rápido, luego G y luego B (mismo orden que una textura Metal 3D).

Solo stdlib.
"""
import argparse
import colorsys
import json
import os
import re
import struct
import sys

SIZE = 64
MAGIC = b"LAIKALUT"
VERSION = 1
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "Packages", "Looks", "Sources", "Looks", "Resources", "LUTs")
MANIFEST = os.path.join(OUT_DIR, "looks.json")


def clamp(x):
    return 0.0 if x < 0.0 else 1.0 if x > 1.0 else x


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(c):
    c = clamp(c)
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def smoothstep(x):
    return x * x * (3 - 2 * x)


def contrast(x, amount):
    """Curva S suave alrededor de 0.5 (valores codificados)."""
    return clamp(x + (smoothstep(clamp(x)) - x) * amount)


def look_identidad(r, g, b):
    return r, g, b


def look_bn_neutro(r, g, b):
    # Luminancia Rec.709 en luz lineal, re-codificada, con un poco de contraste.
    y = 0.2126 * srgb_to_linear(r) + 0.7152 * srgb_to_linear(g) + 0.0722 * srgb_to_linear(b)
    v = contrast(linear_to_srgb(y), 0.35)
    return v, v, v


def look_calido(r, g, b):
    # Balance más cálido en luz lineal, compresión suave de altas luces,
    # sombras levemente levantadas y +8 % de saturación.
    lr, lg, lb = srgb_to_linear(r) * 1.07, srgb_to_linear(g) * 1.0, srgb_to_linear(b) * 0.88
    lr, lg, lb = (c / (1 + 0.07 * c) * 1.07 for c in (lr, lg, lb))
    out = [linear_to_srgb(c) for c in (lr, lg, lb)]
    y = 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
    out = [clamp(y + (c - y) * 1.08) for c in out]
    return tuple(clamp(0.025 + 0.975 * contrast(c, 0.2)) for c in out)


def hue_weight(deg, center, width):
    """Peso 0…1 según la distancia angular al tono `center` (grados), con borde suave."""
    d = abs((deg - center + 180) % 360 - 180)
    return smoothstep(clamp(1 - d / width))


def film_look(r, g, b, p):
    """Receta propia de emulación de negativo color. `p` son los parámetros de cada película
    (los mismos sliders de la vista previa)."""
    warm = p["calidez"]
    lr = srgb_to_linear(r) * (1 + 0.05 * warm)
    lg = srgb_to_linear(g) * (1 + 0.012 * p.get("tinte", 0))   # + verde, − magenta
    lb = srgb_to_linear(b) * (1 - 0.16 * warm)
    # Hombro en luz lineal: las altas luces se comprimen en vez de quemarse.
    k = p["altas_luces"]
    lr, lg, lb = (c / (1 + k * c) * (1 + k) for c in (lr, lg, lb))
    if p.get("mono"):
        y = linear_to_srgb(0.2126 * lr + 0.7152 * lg + 0.0722 * lb)
        lr = lg = lb = srgb_to_linear(y)
    er, eg, eb = (linear_to_srgb(c) for c in (lr, lg, lb))
    # Brillo de medios tonos (como High/Low Key): >0 más claro, <0 más oscuro.
    gamma = 2 ** (-0.12 * p.get("brillo", 0))
    er, eg, eb = (clamp(c) ** gamma for c in (er, eg, eb))

    h, sat, val = colorsys.rgb_to_hsv(er, eg, eb)
    deg = h * 360
    green = hue_weight(deg, 120, 55)
    deg -= p["verdes_oliva"] * green
    sat *= 1 - p["verdes_apagados"] * green
    sat *= 1 - p["azules_apagados"] * hue_weight(deg, 215, 45)
    sat *= 1 + p["rojos_amarillos"] * hue_weight(deg, 30, 40)
    sat *= p["saturacion"]
    er, eg, eb = colorsys.hsv_to_rgb((deg % 360) / 360, clamp(sat), val)

    out = []
    luma = 0.2126 * er + 0.7152 * eg + 0.0722 * eb
    shadow, light = (1 - luma) ** 2, luma ** 2
    for c, tint_shadow, tint_light in zip((er, eg, eb), (-0.006, 0.006, 0.004), (0.015, 0.008, -0.02)):
        c = contrast(c, p["contraste"])
        c = p["negros"] + (p["blancos"] - p["negros"]) * c
        out.append(clamp(c + tint_shadow * p["sombras_frias"] * shadow
                         + tint_light * p["luces_amarillas"] * light))
    return tuple(out)


# Estilo negativo color de consumo ISO 200 (tipo Gold 200): dominante cálida, rojos y amarillos
# ricos, verdes hacia oliva, azules apagados, negros levantados, altas luces suaves.
DORADO_200 = dict(calidez=1.0, altas_luces=0.15, contraste=0.25, negros=0.045, blancos=0.975,
                  verdes_oliva=12, verdes_apagados=0.15, azules_apagados=0.20, rojos_amarillos=0.12,
                  saturacion=1.0, sombras_frias=1.0, luces_amarillas=1.0)

# Estilo negativo profesional de retrato ISO 400 (tipo Portra 400): contraste bajo y mucha
# latitud, colores pastel, pieles cálidas y suaves, verdes y azules contenidos, altas luces
# cremosas.
RETRATO_400 = dict(calidez=0.5, altas_luces=0.35, contraste=0.08, negros=0.035, blancos=0.98,
                   verdes_oliva=6, verdes_apagados=0.25, azules_apagados=0.25, rojos_amarillos=-0.05,
                   saturacion=0.88, sombras_frias=0.8, luces_amarillas=0.7)


# --- Inspiradas en recetas públicas de Ricoh GR -------------------------------------------
# Una receta Ricoh son ajustes sobre el procesado propio de la cámara, así que no se puede
# copiar: se usa como referencia estética. Traducción aproximada de cada ajuste (escala −4…+4):
#   base Image Control → valores de partida (negativo, positivo, cine verde, monocromo)
#   Saturation s → saturacion × (1 + 0.06·s)      Contrast c → contraste + 0.06·c
#   Contrast (Highlight) h → altas_luces − 0.06·h   Contrast (Shadow) k → negros − 0.008·k
#   High/Low Key → brillo                          WB A/G/M → calidez + 0.07·A, tinte ±G/M
# Nitidez, claridad y viñeteo (shading) no son de LUT: quedan para el módulo Effects.

# Bennet 800 (Negative Film; Sat +3, Hue −1, Contrast +2, H −2, S −4, Clarity −1, WB A14 G2):
# negativo cálido y con cuerpo, sombras abiertas.
AMBAR_800 = dict(calidez=1.38, tinte=2, altas_luces=0.42, contraste=0.17, negros=0.062, blancos=0.98,
                 verdes_oliva=4, verdes_apagados=0.2, azules_apagados=0.15, rojos_amarillos=0.0,
                 saturacion=1.0, sombras_frias=1.2, luces_amarillas=0.8)

# Reggie's Color Negative (Negative Film; Sat +2, Contrast +3, H −4, S −1, WB A6): negativo de
# todos los días, balanceado, altas luces muy suaves.
NEGATIVO_DIARIO = dict(calidez=0.82, altas_luces=0.54, contraste=0.23, negros=0.038, blancos=0.98,
                       verdes_oliva=4, verdes_apagados=0.2, azules_apagados=0.15, rojos_amarillos=0.0,
                       saturacion=0.95, sombras_frias=1.2, luces_amarillas=0.8)

# Kodak Chrome (Positive Film; Sat +3, Hue −1, Key −2, Contrast −2, H +2, S −4, Clarity +2,
# WB Daylight A10 G4, exp. +1/3…+1): diapositiva vibrante, azules profundos.
DIAPOSITIVA = dict(calidez=0.9, tinte=4, brillo=-1, altas_luces=0.0, contraste=0.23, negros=0.042,
                   blancos=0.995, verdes_oliva=0, verdes_apagados=0.0, azules_apagados=-0.1,
                   rojos_amarillos=0.1, saturacion=1.3, sombras_frias=0.5, luces_amarillas=0.3)

# Tri-X 400 (Monochrome; Key −1, Contrast +2, H −1, S +2, Shading +1, Clarity +2, grano fuerte):
# B/N documental, negros profundos, altas luces que ruedan suave.
PLATA_400 = dict(mono=1, calidez=0, brillo=-1, altas_luces=0.21, contraste=0.37, negros=0.004,
                 blancos=0.98, verdes_oliva=0, verdes_apagados=0, azules_apagados=0, rojos_amarillos=0,
                 saturacion=1.0, sombras_frias=0, luces_amarillas=0)

# Istanbul (Cinema Green; Sat +3, Key +2, Contrast −1, H −1, S −3, Sharp −2, WB A4 M3, Toning 1):
# cine verde lavado, claro y aireado.
CINE_VERDE = dict(calidez=0.28, tinte=1, brillo=2, altas_luces=0.36, contraste=-0.11, negros=0.074,
                  blancos=0.97, verdes_oliva=-6, verdes_apagados=0.1, azules_apagados=0.2,
                  rojos_amarillos=-0.05, saturacion=1.0, sombras_frias=2.0, luces_amarillas=0.8)


def look_dorado_200(r, g, b):
    return film_look(r, g, b, DORADO_200)


def look_retrato_400(r, g, b):
    return film_look(r, g, b, RETRATO_400)


LOOKS = [
    # (id, nombre visible, función, grano sugerido)
    ("identidad", "Natural", look_identidad, 0.0),
    ("bn-neutro", "B/N Neutro", look_bn_neutro, 0.35),
    ("calido", "Cálido", look_calido, 0.15),
    ("dorado-200", "Dorado 200", look_dorado_200, 0.3),
    ("retrato-400", "Retrato 400", look_retrato_400, 0.2),
    ("ambar-800", "Ámbar 800", lambda r, g, b: film_look(r, g, b, AMBAR_800), 0.3),
    ("negativo-diario", "Negativo Diario", lambda r, g, b: film_look(r, g, b, NEGATIVO_DIARIO), 0.2),
    ("diapositiva", "Diapositiva", lambda r, g, b: film_look(r, g, b, DIAPOSITIVA), 0.1),
    ("plata-400", "Plata 400", lambda r, g, b: film_look(r, g, b, PLATA_400), 0.6),
    ("cine-verde", "Cine Verde", lambda r, g, b: film_look(r, g, b, CINE_VERDE), 0.0),
]


def write_lut(path, texels):
    """texels: lista plana [r, g, b, a, ...] con N³ entradas en orden R→G→B."""
    with open(path, "wb") as f:
        f.write(MAGIC + struct.pack("<II", VERSION, SIZE))
        f.write(struct.pack("<%de" % len(texels), *texels))


def build(fn):
    step = 1.0 / (SIZE - 1)
    texels = []
    for bi in range(SIZE):
        for gi in range(SIZE):
            for ri in range(SIZE):
                texels.extend(fn(ri * step, gi * step, bi * step))
                texels.append(1.0)
    return texels


# --- Catálogo -----------------------------------------------------------------

def load_manifest():
    if not os.path.exists(MANIFEST):
        return {"version": 1, "lutSize": SIZE, "looks": []}
    with open(MANIFEST, encoding="utf-8") as f:
        return json.load(f)


def save_manifest(manifest):
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")


def upsert(manifest, entry):
    looks = manifest["looks"]
    for i, look in enumerate(looks):
        if look["id"] == entry["id"]:
            looks[i] = entry
            return
    looks.append(entry)


def generate():
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = load_manifest()
    for look_id, name, fn, grain in LOOKS:
        filename = look_id + ".lut"
        write_lut(os.path.join(OUT_DIR, filename), build(fn))
        upsert(manifest, {"id": look_id, "name": name, "lut": filename, "grain": grain})
        print("escrito", filename)
    save_manifest(manifest)
    print("actualizado looks.json")


# --- Importación de .cube -------------------------------------------------------

def read_cube(path):
    """Devuelve (n, datos, dominio_min, dominio_max) de un .cube 3D."""
    n, data = None, []
    dmin, dmax = (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            key = line.split()[0].upper()
            if key == "LUT_3D_SIZE":
                n = int(line.split()[1])
            elif key == "DOMAIN_MIN":
                dmin = tuple(float(v) for v in line.split()[1:4])
            elif key == "DOMAIN_MAX":
                dmax = tuple(float(v) for v in line.split()[1:4])
            elif key in ("LUT_1D_SIZE", "LUT_1D_INPUT_RANGE"):
                sys.exit("%s: tiene un LUT/shaper 1D; todavía no está soportado" % path)
            elif re.match(r"^[A-Z_]+$", key):
                continue  # TITLE, LUT_3D_INPUT_RANGE, etc.
            else:
                data.append(tuple(float(v) for v in line.split()[:3]))
    if n is None:
        sys.exit("%s: falta LUT_3D_SIZE (¿es un LUT 3D .cube?)" % path)
    if len(data) != n ** 3:
        sys.exit("%s: se esperaban %d filas y hay %d" % (path, n ** 3, len(data)))
    return n, data, dmin, dmax


def gamma24_decode(c):
    return clamp(c) ** 2.4


def gamma24_encode(c):
    return clamp(c) ** (1 / 2.4)


INPUTS = {
    # nombre: (de la app al LUT, del LUT a la app)
    "srgb": (lambda c: c, lambda c: c),
    "rec709": (lambda c: gamma24_encode(srgb_to_linear(c)), lambda c: linear_to_srgb(gamma24_decode(c))),
}


def cube_sampler(path, input_space):
    n, data, dmin, dmax = read_cube(path)
    to_lut, from_lut = INPUTS[input_space]

    def at(ri, gi, bi):
        return data[ri + gi * n + bi * n * n]

    def sample(r, g, b):
        rgb = [to_lut(c) for c in (r, g, b)]
        # Normalizar al dominio del .cube y luego interpolar en la grilla (trilineal).
        coords = [clamp((c - lo) / (hi - lo)) * (n - 1) for c, lo, hi in zip(rgb, dmin, dmax)]
        i0 = [min(int(c), n - 2) for c in coords]
        t = [c - i for c, i in zip(coords, i0)]
        out = [0.0, 0.0, 0.0]
        for dr in (0, 1):
            for dg in (0, 1):
                for db in (0, 1):
                    w = ((t[0] if dr else 1 - t[0]) * (t[1] if dg else 1 - t[1])
                         * (t[2] if db else 1 - t[2]))
                    if w:
                        v = at(i0[0] + dr, i0[1] + dg, i0[2] + db)
                        out = [o + w * c for o, c in zip(out, v)]
        return tuple(from_lut(clamp(o)) for o in out)

    return sample


def convert(src, dst, input_space):
    write_lut(dst, build(cube_sampler(src, input_space)))
    print("escrito", dst)


def add(src, look_id, name, grain, input_space):
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", look_id):
        sys.exit("--id: solo minúsculas, números y guiones (p. ej. 'kodak-calido')")
    filename = look_id + ".lut"
    convert(src, os.path.join(OUT_DIR, filename), input_space)
    manifest = load_manifest()
    upsert(manifest, {"id": look_id, "name": name, "lut": filename, "grain": grain,
                      "source": os.path.basename(src), "input": input_space})
    save_manifest(manifest)
    print("agregado '%s' a looks.json" % look_id)


def remove(look_id):
    if look_id in {l[0] for l in LOOKS}:
        sys.exit("'%s' es un Look propio generado por este script; sacalo de LOOKS" % look_id)
    manifest = load_manifest()
    entry = next((l for l in manifest["looks"] if l["id"] == look_id), None)
    if entry is None:
        sys.exit("no existe '%s'" % look_id)
    manifest["looks"].remove(entry)
    path = os.path.join(OUT_DIR, entry["lut"])
    if os.path.exists(path):
        os.remove(path)
    save_manifest(manifest)
    print("quitado", look_id)


def list_looks():
    for look in load_manifest()["looks"]:
        origin = look.get("source", "propio")
        print("%-16s %-20s grano %.2f  %s" % (look["id"], look["name"], look["grain"], origin))


def main():
    parser = argparse.ArgumentParser(description="Catálogo de LUTs de Looks")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("generate")
    p_add = sub.add_parser("add")
    p_add.add_argument("cube")
    p_add.add_argument("--id", required=True)
    p_add.add_argument("--name", required=True)
    p_add.add_argument("--grain", type=float, default=0.0)
    p_add.add_argument("--input", choices=sorted(INPUTS), default="srgb")
    p_rm = sub.add_parser("remove")
    p_rm.add_argument("id")
    sub.add_parser("list")
    p_conv = sub.add_parser("convert")
    p_conv.add_argument("cube")
    p_conv.add_argument("out")
    p_conv.add_argument("--input", choices=sorted(INPUTS), default="srgb")
    args = parser.parse_args()

    if args.cmd in (None, "generate"):
        generate()
    elif args.cmd == "add":
        add(args.cube, args.id, args.name, args.grain, args.input)
    elif args.cmd == "remove":
        remove(args.id)
    elif args.cmd == "list":
        list_looks()
    elif args.cmd == "convert":
        convert(args.cube, args.out, args.input)


if __name__ == "__main__":
    main()

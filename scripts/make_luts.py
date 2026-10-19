#!/usr/bin/env python3
"""Genera los LUTs 3D de ejemplo (propios) para el paquete Looks.

Uso:
  scripts/make_luts.py                      # regenera los LUTs incluidos + looks.json
  scripts/make_luts.py convert in.cube out.lut   # convierte un .cube propio (p. ej. de Resolve)

Formato .lut (propio): cabecera de 16 bytes = b"LAIKALUT" + uint32 LE versión (1)
+ uint32 LE tamaño N (64), seguida de N³ texeles RGBA float16 little-endian con
R variando más rápido, luego G y luego B (mismo orden que una textura Metal 3D).

Todo se calcula con fórmulas propias; no se usa material de terceros. Solo stdlib.
"""
import json
import os
import struct
import sys

SIZE = 64
MAGIC = b"LAIKALUT"
VERSION = 1
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "Packages", "Looks", "Sources", "Looks", "Resources", "LUTs")


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


LOOKS = [
    # (id, nombre visible, función, grano sugerido)
    ("identidad", "Natural", look_identidad, 0.0),
    ("bn-neutro", "B/N Neutro", look_bn_neutro, 0.35),
    ("calido", "Cálido", look_calido, 0.15),
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


def generate():
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {"version": 1, "lutSize": SIZE, "looks": []}
    for look_id, name, fn, grain in LOOKS:
        filename = look_id + ".lut"
        write_lut(os.path.join(OUT_DIR, filename), build(fn))
        manifest["looks"].append({"id": look_id, "name": name, "lut": filename, "grain": grain})
        print("escrito", filename)
    with open(os.path.join(OUT_DIR, "looks.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("escrito looks.json")


def read_cube(path):
    n, data = None, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key = line.split()[0]
            if key == "LUT_3D_SIZE":
                n = int(line.split()[1])
            elif key in ("TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_SIZE"):
                if key == "LUT_1D_SIZE":
                    sys.exit("Solo se soportan .cube 3D")
                continue
            else:
                data.append(tuple(float(v) for v in line.split()[:3]))
    if n is None or len(data) != n ** 3:
        sys.exit("Archivo .cube inválido")
    return n, data


def convert(src, dst):
    n, data = read_cube(src)

    def at(ri, gi, bi):
        return data[ri + gi * n + bi * n * n]

    def sample(r, g, b):
        # Interpolación trilineal en la grilla de origen.
        coords = [c * (n - 1) for c in (r, g, b)]
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
        return tuple(clamp(o) for o in out)

    write_lut(dst, build(sample))
    print("escrito", dst)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        generate()
    elif len(sys.argv) == 4 and sys.argv[1] == "convert":
        convert(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)

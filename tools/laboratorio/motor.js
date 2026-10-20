// Motor de color del Laboratorio: mismas cuentas que `film_look()` en scripts/make_luts.py y que
// FilmRecipe.swift (en double, con la semántica de `colorsys` y `%` de Python). Si cambia la
// fórmula, cambiar los tres y correr `node tools/laboratorio/verificar.js`.
(function (global) {
  "use strict";

  const clamp = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
  const srgbToLinear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const linearToSrgb = (c) => {
    c = clamp(c);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * c ** (1 / 2.4) - 0.055;
  };
  const smoothstep = (x) => x * x * (3 - 2 * x);
  // Curva S suave alrededor de 0.5 (valores codificados).
  const contrast = (x, amount) => clamp(x + (smoothstep(clamp(x)) - x) * amount);

  // `a % b` de Python con floats: el resultado tiene el signo de `b`.
  function pyMod(a, b) {
    let mod = a % b;
    if (mod !== 0) {
      if (b < 0 !== mod < 0) mod += b;
    } else {
      mod = b < 0 ? -0 : 0;
    }
    return mod;
  }

  function hueWeight(deg, center, width) {
    const d = Math.abs(pyMod(deg - center + 180, 360) - 180);
    return smoothstep(clamp(1 - d / width));
  }

  // colorsys.rgb_to_hsv
  function rgbToHsv(r, g, b) {
    const maxc = Math.max(r, g, b), minc = Math.min(r, g, b);
    const v = maxc;
    if (minc === maxc) return [0, 0, v];
    const rangec = maxc - minc;
    const s = rangec / maxc;
    const rc = (maxc - r) / rangec, gc = (maxc - g) / rangec, bc = (maxc - b) / rangec;
    let h;
    if (r === maxc) h = bc - gc;
    else if (g === maxc) h = 2.0 + rc - bc;
    else h = 4.0 + gc - rc;
    return [pyMod(h / 6.0, 1.0), s, v];
  }

  // colorsys.hsv_to_rgb
  function hsvToRgb(h, s, v) {
    if (s === 0.0) return [v, v, v];
    let i = Math.trunc(h * 6.0);
    const f = h * 6.0 - i;
    const p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f));
    i = ((i % 6) + 6) % 6;
    switch (i) {
      case 0: return [v, t, p];
      case 1: return [q, v, p];
      case 2: return [p, v, t];
      case 3: return [p, q, v];
      case 4: return [t, p, v];
      default: return [v, p, q];
    }
  }

  // film_look(r, g, b, p): `p` con las claves de looks.json.
  function filmLook(r, g, b, p) {
    const warm = p.calidez;
    let lr = srgbToLinear(r) * (1 + 0.05 * warm);
    let lg = srgbToLinear(g) * (1 + 0.012 * (p.tinte || 0));
    let lb = srgbToLinear(b) * (1 - 0.16 * warm);
    const k = p.altas_luces;
    lr = (lr / (1 + k * lr)) * (1 + k);
    lg = (lg / (1 + k * lg)) * (1 + k);
    lb = (lb / (1 + k * lb)) * (1 + k);
    if (p.mono) {
      const y = linearToSrgb(0.2126 * lr + 0.7152 * lg + 0.0722 * lb);
      lr = lg = lb = srgbToLinear(y);
    }
    let er = linearToSrgb(lr), eg = linearToSrgb(lg), eb = linearToSrgb(lb);
    const gamma = 2 ** (-0.12 * (p.brillo || 0));
    er = clamp(er) ** gamma;
    eg = clamp(eg) ** gamma;
    eb = clamp(eb) ** gamma;

    let [h, sat, val] = rgbToHsv(er, eg, eb);
    let deg = h * 360;
    const green = hueWeight(deg, 120, 55);
    deg -= p.verdes_oliva * green;
    sat *= 1 - p.verdes_apagados * green;
    sat *= 1 - p.azules_apagados * hueWeight(deg, 215, 45);
    sat *= 1 + p.rojos_amarillos * hueWeight(deg, 30, 40);
    sat *= p.saturacion;
    [er, eg, eb] = hsvToRgb(pyMod(deg, 360) / 360, clamp(sat), val);

    const luma = 0.2126 * er + 0.7152 * eg + 0.0722 * eb;
    const shadow = (1 - luma) ** 2, light = luma ** 2;
    const finish = (c, tintShadow, tintLight) => {
      c = contrast(c, p.contraste);
      c = p.negros + (p.blancos - p.negros) * c;
      return clamp(c + tintShadow * p.sombras_frias * shadow + tintLight * p.luces_amarillas * light);
    };
    return [finish(er, -0.006, 0.015), finish(eg, 0.006, 0.008), finish(eb, 0.004, -0.02)];
  }

  // Looks de fórmula fija (los que la app trae como .lut).
  const FORMULAS = {
    identidad: (r, g, b) => [r, g, b],
    "bn-neutro": (r, g, b) => {
      const y = 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b);
      const v = contrast(linearToSrgb(y), 0.35);
      return [v, v, v];
    },
    calido: (r, g, b) => {
      let lin = [srgbToLinear(r) * 1.07, srgbToLinear(g) * 1.0, srgbToLinear(b) * 0.88];
      lin = lin.map((c) => (c / (1 + 0.07 * c)) * 1.07);
      let out = lin.map(linearToSrgb);
      const y = 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2];
      out = out.map((c) => clamp(y + (c - y) * 1.08));
      return out.map((c) => clamp(0.025 + 0.975 * contrast(c, 0.2)));
    },
  };

  // LUT N³ RGBA en Float32, R variando más rápido (mismo orden que la app).
  function makeLUT(fn, size) {
    const out = new Float32Array(size * size * size * 4);
    const step = 1 / (size - 1);
    let i = 0;
    for (let bi = 0; bi < size; bi++) {
      for (let gi = 0; gi < size; gi++) {
        for (let ri = 0; ri < size; ri++) {
          const rgb = fn(ri * step, gi * step, bi * step);
          out[i] = rgb[0];
          out[i + 1] = rgb[1];
          out[i + 2] = rgb[2];
          out[i + 3] = 1;
          i += 4;
        }
      }
    }
    return out;
  }

  // Función de color de un Look del catálogo o propio.
  function lookFunction(look) {
    if (look.recipe) return (r, g, b) => filmLook(r, g, b, look.recipe);
    return FORMULAS[look.id] || null;
  }

  // Igual que FilmRecipe.parameters (RecipeParameters.swift).
  const PARAMETROS = [
    { id: "brillo", name: "Brillo", group: "Tono", min: -4, max: 4 },
    { id: "contraste", name: "Contraste", group: "Tono", min: -0.5, max: 0.6 },
    { id: "altas_luces", name: "Altas luces suaves", group: "Tono", min: 0, max: 1 },
    { id: "negros", name: "Negros levantados", group: "Tono", min: 0, max: 0.15 },
    { id: "blancos", name: "Blancos", group: "Tono", min: 0.85, max: 1 },
    { id: "calidez", name: "Calidez", group: "Color", min: -1, max: 2 },
    { id: "tinte", name: "Tinte (verde/magenta)", group: "Color", min: -6, max: 6 },
    { id: "saturacion", name: "Saturación", group: "Color", min: 0, max: 1.6 },
    { id: "rojos_amarillos", name: "Rojos y amarillos", group: "Color", min: -0.5, max: 0.5 },
    { id: "verdes_oliva", name: "Verdes hacia oliva", group: "Color", min: -20, max: 20 },
    { id: "verdes_apagados", name: "Verdes apagados", group: "Color", min: -0.5, max: 1 },
    { id: "azules_apagados", name: "Azules apagados", group: "Color", min: -0.5, max: 1 },
    { id: "sombras_frias", name: "Sombras frías", group: "Virado", min: -2, max: 3 },
    { id: "luces_amarillas", name: "Luces amarillas", group: "Virado", min: -2, max: 3 },
  ];

  const NEUTRA = {
    calidez: 0, tinte: 0, brillo: 0, altas_luces: 0, contraste: 0, negros: 0, blancos: 1,
    verdes_oliva: 0, verdes_apagados: 0, azules_apagados: 0, rojos_amarillos: 0, saturacion: 1,
    sombras_frias: 0, luces_amarillas: 0, mono: 0,
  };

  // Receta completa con cada valor en su rango (como FilmRecipe.clamped).
  function clampRecipe(recipe) {
    const out = { ...NEUTRA };
    for (const p of PARAMETROS) {
      const v = Number(recipe && recipe[p.id]);
      out[p.id] = Number.isFinite(v) ? Math.min(Math.max(v, p.min), p.max) : NEUTRA[p.id];
    }
    out.mono = recipe && Number(recipe.mono) ? 1 : 0;
    return out;
  }

  const clampEffect = (x) => {
    const v = Number(x);
    return Number.isFinite(v) ? Math.min(Math.max(v, -1), 1) : 0;
  };

  // Texto para compartir, mismo formato que LookShare.text(for:).
  function shareText(look) {
    const payload = { effects: undefined, formato: "camera.app/receta", grain: look.grain, name: look.name,
                      recipe: look.recipe, version: 1 };
    const e = look.effects;
    if (e && (e.nitidez || e.claridad || e.vineteo)) {
      payload.effects = { claridad: e.claridad || 0, nitidez: e.nitidez || 0, vineteo: e.vineteo || 0 };
    }
    return JSON.stringify(payload, null, 2);
  }

  // Lee una receta pegada, como LookShare.look(from:id:). Devuelve null si no hay.
  function parseShared(text) {
    const start = text.indexOf("{"), end = text.lastIndexOf("}");
    if (start < 0 || end <= start) return null;
    let payload;
    try {
      payload = JSON.parse(text.slice(start, end + 1));
    } catch (e) {
      return null;
    }
    if (!payload || typeof payload.recipe !== "object" || payload.recipe === null) return null;
    const required = ["calidez", "altas_luces", "contraste", "negros", "blancos", "verdes_oliva", "verdes_apagados",
                      "azules_apagados", "rojos_amarillos", "saturacion", "sombras_frias", "luces_amarillas"];
    if (!required.every((k) => typeof payload.recipe[k] === "number")) return null;
    const name = String(payload.name || "").trim().slice(0, 40);
    const grain = Number(payload.grain);
    const fx = payload.effects || {};
    return {
      name: name || "Receta importada",
      recipe: clampRecipe(payload.recipe),
      grain: Number.isFinite(grain) ? Math.min(Math.max(grain, 0), 1) : 0,
      effects: { nitidez: clampEffect(fx.nitidez), claridad: clampEffect(fx.claridad), vineteo: clampEffect(fx.vineteo) },
    };
  }

  global.Motor = { filmLook, FORMULAS, makeLUT, lookFunction, PARAMETROS, NEUTRA, clampRecipe, shareText, parseShared };
})(typeof window !== "undefined" ? window : globalThis);

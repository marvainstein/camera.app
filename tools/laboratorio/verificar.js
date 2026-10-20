// Compara el motor JS del Laboratorio con los LUTs que genera Python: las referencias 17³ de las
// recetas (tests de Swift) y los .lut 64³ de fórmula fija del bundle.
//   node tools/laboratorio/verificar.js
"use strict";
const fs = require("fs");
const path = require("path");
require("./motor.js");
const { Motor } = globalThis;

const root = path.join(__dirname, "..", "..");
const luts = path.join(root, "Packages/Looks/Sources/Looks/Resources/LUTs");
const references = path.join(root, "Packages/Looks/Tests/LooksTests/Resources");

function half(bits) {
  const sign = bits & 0x8000 ? -1 : 1, exp = (bits >> 10) & 0x1f, frac = bits & 0x3ff;
  if (exp === 0) return sign * 2 ** -14 * (frac / 1024);
  if (exp === 31) return frac ? NaN : sign * Infinity;
  return sign * 2 ** (exp - 15) * (1 + frac / 1024);
}

function readLUT(file) {
  const data = fs.readFileSync(file);
  if (data.toString("latin1", 0, 8) !== "LAIKALUT") throw new Error(file + ": cabecera inválida");
  const size = data.readUInt32LE(12);
  const values = new Float32Array(size ** 3 * 4);
  for (let i = 0; i < values.length; i++) values[i] = half(data.readUInt16LE(16 + i * 2));
  return { size, values };
}

const catalog = JSON.parse(fs.readFileSync(path.join(luts, "looks.json"), "utf8")).looks;
let failed = false;
for (const look of catalog) {
  const fn = Motor.lookFunction(look);
  const file = look.recipe ? path.join(references, look.id + ".lut") : path.join(luts, look.lut || "");
  if (!fn || !fs.existsSync(file)) {
    console.log(`${look.id.padEnd(16)} sin referencia, salteado`);
    continue;
  }
  const reference = readLUT(file);
  const generated = Motor.makeLUT(fn, reference.size);
  let worst = 0;
  for (let i = 0; i < generated.length; i++) worst = Math.max(worst, Math.abs(generated[i] - reference.values[i]));
  // float16 tiene ~1/2048 de resolución en 0.5…1: la tolerancia es la misma que en los tests de Swift.
  const ok = worst <= 1 / 1024;
  failed ||= !ok;
  console.log(`${look.id.padEnd(16)} ${reference.size}³  máx. dif. ${worst.toExponential(2)}  ${ok ? "ok" : "FALLA"}`);
}

const neutral = Motor.makeLUT((r, g, b) => Motor.filmLook(r, g, b, Motor.NEUTRA), 17);
const identity = Motor.makeLUT(Motor.FORMULAS.identidad, 17);
const neutralError = neutral.reduce((m, v, i) => Math.max(m, Math.abs(v - identity[i])), 0);
console.log(`receta neutra     17³  máx. dif. ${neutralError.toExponential(2)}  ${neutralError < 1e-9 ? "ok" : "FALLA"}`);
failed ||= neutralError >= 1e-9;

const shared = Motor.parseShared("mirá esta: " + Motor.shareText(catalog.find((l) => l.id === "plata-400")) + " chau");
const roundTrip = shared && shared.name === "Plata 400" && shared.recipe.mono === 1 && shared.effects.vineteo === 0.25;
console.log(`compartir/pegar         ${roundTrip ? "ok" : "FALLA"}`);
failed ||= !roundTrip;
process.exit(failed ? 1 : 0);

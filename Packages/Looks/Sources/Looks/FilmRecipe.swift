import CryptoKit
import Foundation

/// Receta propia de emulación de película: los parámetros de `film_look()` en
/// `scripts/make_luts.py`, con los mismos nombres que en `looks.json`.
///
/// El LUT se genera en el dispositivo. La cuenta se hace en `Double`, con las mismas operaciones
/// y en el mismo orden que en Python, para que coincida con las referencias del script.
public struct FilmRecipe: Sendable, Hashable, Codable {
    public var calidez: Double
    /// + verde, − magenta.
    public var tinte: Double
    /// Brillo de medios tonos (como High/Low Key): > 0 más claro, < 0 más oscuro.
    public var brillo: Double
    public var altasLuces: Double
    public var contraste: Double
    public var negros: Double
    public var blancos: Double
    public var verdesOliva: Double
    public var verdesApagados: Double
    public var azulesApagados: Double
    public var rojosAmarillos: Double
    public var saturacion: Double
    public var sombrasFrias: Double
    public var lucesAmarillas: Double
    /// Distinto de 0: blanco y negro.
    public var mono: Double
    /// Filtro de color delante del B/N: fuerza 0…1 y tono en grados (0 rojo, 60 amarillo…).
    public var filtro: Double
    public var filtroTono: Double
    /// Virado partido: fuerza y tono (grados) en las sombras y en las luces.
    public var viradoSombras: Double
    public var viradoSombrasTono: Double
    public var viradoLuces: Double
    public var viradoLucesTono: Double

    /// Sube cuando cambia la fórmula de `apply`, para invalidar los LUTs cacheados.
    public static let generatorVersion = 2

    public init(calidez: Double, tinte: Double = 0, brillo: Double = 0, altasLuces: Double,
                contraste: Double, negros: Double, blancos: Double, verdesOliva: Double,
                verdesApagados: Double, azulesApagados: Double, rojosAmarillos: Double,
                saturacion: Double, sombrasFrias: Double, lucesAmarillas: Double, mono: Double = 0,
                filtro: Double = 0, filtroTono: Double = 0, viradoSombras: Double = 0, viradoSombrasTono: Double = 0,
                viradoLuces: Double = 0, viradoLucesTono: Double = 0) {
        self.calidez = calidez
        self.tinte = tinte
        self.brillo = brillo
        self.altasLuces = altasLuces
        self.contraste = contraste
        self.negros = negros
        self.blancos = blancos
        self.verdesOliva = verdesOliva
        self.verdesApagados = verdesApagados
        self.azulesApagados = azulesApagados
        self.rojosAmarillos = rojosAmarillos
        self.saturacion = saturacion
        self.sombrasFrias = sombrasFrias
        self.lucesAmarillas = lucesAmarillas
        self.mono = mono
        self.filtro = filtro
        self.filtroTono = filtroTono
        self.viradoSombras = viradoSombras
        self.viradoSombrasTono = viradoSombrasTono
        self.viradoLuces = viradoLuces
        self.viradoLucesTono = viradoLucesTono
    }

    enum CodingKeys: String, CodingKey {
        case calidez, tinte, brillo, contraste, negros, blancos, saturacion, mono, filtro
        case filtroTono = "filtro_tono"
        case viradoSombras = "virado_sombras"
        case viradoSombrasTono = "virado_sombras_tono"
        case viradoLuces = "virado_luces"
        case viradoLucesTono = "virado_luces_tono"
        case altasLuces = "altas_luces"
        case verdesOliva = "verdes_oliva"
        case verdesApagados = "verdes_apagados"
        case azulesApagados = "azules_apagados"
        case rojosAmarillos = "rojos_amarillos"
        case sombrasFrias = "sombras_frias"
        case lucesAmarillas = "luces_amarillas"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calidez = try c.decode(Double.self, forKey: .calidez)
        tinte = try c.decodeIfPresent(Double.self, forKey: .tinte) ?? 0
        brillo = try c.decodeIfPresent(Double.self, forKey: .brillo) ?? 0
        altasLuces = try c.decode(Double.self, forKey: .altasLuces)
        contraste = try c.decode(Double.self, forKey: .contraste)
        negros = try c.decode(Double.self, forKey: .negros)
        blancos = try c.decode(Double.self, forKey: .blancos)
        verdesOliva = try c.decode(Double.self, forKey: .verdesOliva)
        verdesApagados = try c.decode(Double.self, forKey: .verdesApagados)
        azulesApagados = try c.decode(Double.self, forKey: .azulesApagados)
        rojosAmarillos = try c.decode(Double.self, forKey: .rojosAmarillos)
        saturacion = try c.decode(Double.self, forKey: .saturacion)
        sombrasFrias = try c.decode(Double.self, forKey: .sombrasFrias)
        lucesAmarillas = try c.decode(Double.self, forKey: .lucesAmarillas)
        mono = try c.decodeIfPresent(Double.self, forKey: .mono) ?? 0
        filtro = try c.decodeIfPresent(Double.self, forKey: .filtro) ?? 0
        filtroTono = try c.decodeIfPresent(Double.self, forKey: .filtroTono) ?? 0
        viradoSombras = try c.decodeIfPresent(Double.self, forKey: .viradoSombras) ?? 0
        viradoSombrasTono = try c.decodeIfPresent(Double.self, forKey: .viradoSombrasTono) ?? 0
        viradoLuces = try c.decodeIfPresent(Double.self, forKey: .viradoLuces) ?? 0
        viradoLucesTono = try c.decodeIfPresent(Double.self, forKey: .viradoLucesTono) ?? 0
    }

    /// Hash estable entre ejecuciones y dispositivos (a diferencia de `hashValue`): SHA-256 del
    /// JSON con claves ordenadas, en hex. Sirve de clave del caché en disco.
    public var stableHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Genera el LUT evaluando la receta en cada nodo de la grilla, un plano B por tarea.
    ///
    /// Con `base` (por ejemplo, un `.cube` importado) la receta se aplica sobre la salida de ese LUT:
    /// la receta neutra lo deja como está.
    public func makeLUT(size: Int = 64, base: LUT3D? = nil) -> LUT3D {
        let plane = size * size * 4
        var floats = [Float](repeating: 0, count: size * plane)
        let step = 1.0 / Double(size - 1)
        let baseValues = base?.floatTexels
        floats.withUnsafeMutableBufferPointer { buffer in
            let out = SendableBuffer(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: size) { bi in
                var i = bi * plane
                for gi in 0..<size {
                    for ri in 0..<size {
                        var input = (Double(ri) * step, Double(gi) * step, Double(bi) * step)
                        if let base, let baseValues {
                            let v: SIMD3<Float>
                            if base.size == size {
                                v = SIMD3<Float>(baseValues[i], baseValues[i + 1], baseValues[i + 2])
                            } else {
                                let node = SIMD3<Float>(Float(input.0), Float(input.1), Float(input.2))
                                v = base.apply(node, values: baseValues)
                            }
                            input = (Double(v.x), Double(v.y), Double(v.z))
                        }
                        let rgb = apply(input.0, input.1, input.2)
                        out.base[i] = Float(rgb.0)
                        out.base[i + 1] = Float(rgb.1)
                        out.base[i + 2] = Float(rgb.2)
                        out.base[i + 3] = 1
                        i += 4
                    }
                }
            }
        }
        // No puede fallar: la cantidad de texeles coincide con `size` por construcción.
        return try! LUT3D(size: size, texels: LUT3D.halfBits(from: floats))
    }

    /// `film_look(r, g, b, p)` de `scripts/make_luts.py`, valores codificados 0…1.
    public func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        typealias F = FilmMath
        let warm = calidez
        var lr = F.srgbToLinear(r) * (1 + 0.05 * warm)
        var lg = F.srgbToLinear(g) * (1 + 0.012 * tinte)
        var lb = F.srgbToLinear(b) * (1 - 0.16 * warm)
        // Hombro en luz lineal: las altas luces se comprimen en vez de quemarse.
        let k = altasLuces
        lr = lr / (1 + k * lr) * (1 + k)
        lg = lg / (1 + k * lg) * (1 + k)
        lb = lb / (1 + k * lb) * (1 + k)
        if mono != 0 {
            // Filtro de color delante del B/N: pasa su color y oscurece el complementario.
            var wr = 0.2126, wg = 0.7152, wb = 0.0722
            if filtro != 0 {
                let (fr, fg, fb) = F.hsvToRGB(F.pyMod(filtroTono, 360) / 360, F.clamp(filtro), 1.0)
                wr *= fr
                wg *= fg
                wb *= fb
                let total = wr + wg + wb
                wr /= total
                wg /= total
                wb /= total
            }
            let y = F.linearToSRGB(wr * lr + wg * lg + wb * lb)
            lr = F.srgbToLinear(y)
            lg = lr
            lb = lr
        }
        var er = F.linearToSRGB(lr), eg = F.linearToSRGB(lg), eb = F.linearToSRGB(lb)
        let gamma = pow(2, -0.12 * brillo)
        er = pow(F.clamp(er), gamma)
        eg = pow(F.clamp(eg), gamma)
        eb = pow(F.clamp(eb), gamma)

        var (h, sat, val) = F.rgbToHSV(er, eg, eb)
        var deg = h * 360
        let green = F.hueWeight(deg, 120, 55)
        deg -= verdesOliva * green
        sat *= 1 - verdesApagados * green
        sat *= 1 - azulesApagados * F.hueWeight(deg, 215, 45)
        sat *= 1 + rojosAmarillos * F.hueWeight(deg, 30, 40)
        sat *= saturacion
        h = F.pyMod(deg, 360) / 360
        (er, eg, eb) = F.hsvToRGB(h, F.clamp(sat), val)

        let luma = 0.2126 * er + 0.7152 * eg + 0.0722 * eb
        let shadow = pow(1 - luma, 2), light = pow(luma, 2)
        // Virado partido: un tono en las sombras y otro en las luces.
        var tonedShadow = (0.0, 0.0, 0.0), tonedLight = (0.0, 0.0, 0.0)
        if viradoSombras != 0 {
            let d = F.toneOffset(viradoSombrasTono), k = 0.12 * viradoSombras
            tonedShadow = (k * d.0 * (1 - luma), k * d.1 * (1 - luma), k * d.2 * (1 - luma))
        }
        if viradoLuces != 0 {
            let d = F.toneOffset(viradoLucesTono), k = 0.12 * viradoLuces
            tonedLight = (k * d.0 * luma, k * d.1 * luma, k * d.2 * luma)
        }
        func finish(_ c: Double, _ tintShadow: Double, _ tintLight: Double, _ toneS: Double, _ toneL: Double) -> Double {
            var c = F.contrast(c, contraste)
            c = negros + (blancos - negros) * c
            return F.clamp(c + tintShadow * sombrasFrias * shadow + tintLight * lucesAmarillas * light + toneS + toneL)
        }
        return (finish(er, -0.006, 0.015, tonedShadow.0, tonedLight.0),
                finish(eg, 0.006, 0.008, tonedShadow.1, tonedLight.1),
                finish(eb, 0.004, -0.02, tonedShadow.2, tonedLight.2))
    }
}

/// Puntero para que cada tarea de `concurrentPerform` escriba su propio plano, sin solaparse.
private struct SendableBuffer: @unchecked Sendable {
    let base: UnsafeMutablePointer<Float>
}

/// Helpers de `scripts/make_luts.py`, con la semántica de Python (incluidos `colorsys` y `%`).
enum FilmMath {
    static func clamp(_ x: Double) -> Double {
        x < 0 ? 0 : x > 1 ? 1 : x
    }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ c: Double) -> Double {
        let c = clamp(c)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// `tone_offset`: desvío de color (sin cambiar la luminancia) del tono `deg` a saturación plena.
    static func toneOffset(_ deg: Double) -> (Double, Double, Double) {
        let (r, g, b) = hsvToRGB(pyMod(deg, 360) / 360, 1.0, 1.0)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (r - y, g - y, b - y)
    }

    static func smoothstep(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }

    /// Curva S suave alrededor de 0.5 (valores codificados).
    static func contrast(_ x: Double, _ amount: Double) -> Double {
        clamp(x + (smoothstep(clamp(x)) - x) * amount)
    }

    /// Peso 0…1 según la distancia angular al tono `center` (grados), con borde suave.
    static func hueWeight(_ deg: Double, _ center: Double, _ width: Double) -> Double {
        let d = abs(pyMod(deg - center + 180, 360) - 180)
        return smoothstep(clamp(1 - d / width))
    }

    /// `a % b` de Python con floats: el resultado tiene el signo de `b`.
    static func pyMod(_ a: Double, _ b: Double) -> Double {
        var mod = fmod(a, b)
        if mod != 0 {
            if (b < 0) != (mod < 0) { mod += b }
        } else {
            mod = b < 0 ? -0.0 : 0.0
        }
        return mod
    }

    /// `colorsys.rgb_to_hsv`.
    static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        let rangec = maxc - minc
        let v = maxc
        if minc == maxc { return (0, 0, v) }
        let s = rangec / maxc
        let rc = (maxc - r) / rangec, gc = (maxc - g) / rangec, bc = (maxc - b) / rangec
        var h: Double
        if r == maxc {
            h = bc - gc
        } else if g == maxc {
            h = 2.0 + rc - bc
        } else {
            h = 4.0 + gc - rc
        }
        h = pyMod(h / 6.0, 1.0)
        return (h, s, v)
    }

    /// `colorsys.hsv_to_rgb`.
    static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        if s == 0.0 { return (v, v, v) }
        var i = Int(h * 6.0)
        let f = h * 6.0 - Double(i)
        let p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f))
        i = ((i % 6) + 6) % 6
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

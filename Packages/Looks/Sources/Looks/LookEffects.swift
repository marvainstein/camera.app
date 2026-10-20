import Foundation

/// Lo de una receta que no entra en un LUT porque depende de los píxeles vecinos o de la
/// posición en el cuadro: nitidez, claridad (contraste local), viñeteo, halation y bloom.
///
/// Nitidez, claridad y viñeteo van de −1 a 1 (una receta Ricoh de −4…+4 se divide por 4);
/// halation y bloom, de 0 a 1. 0 = sin efecto. En `looks.json` va como
/// `"effects": {"nitidez": …, "claridad": …, "vineteo": …, "halation": …, "bloom": …}`; los que
/// faltan valen 0.
public struct LookEffects: Sendable, Hashable, Codable {
    /// > 0 realza bordes finos, < 0 los suaviza.
    public var nitidez: Float
    /// > 0 más contraste local en medios tonos, < 0 más suave ("soñador").
    public var claridad: Float
    /// > 0 oscurece las esquinas, < 0 las aclara.
    public var vineteo: Float
    /// Halo rojo anaranjado alrededor de las luces fuertes, como en la película.
    public var halation: Float
    /// Las luces fuertes se derraman alrededor.
    public var bloom: Float

    public static let neutral = LookEffects()

    public init(nitidez: Float = 0, claridad: Float = 0, vineteo: Float = 0, halation: Float = 0, bloom: Float = 0) {
        self.nitidez = nitidez
        self.claridad = claridad
        self.vineteo = vineteo
        self.halation = halation
        self.bloom = bloom
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nitidez = try c.decodeIfPresent(Float.self, forKey: .nitidez) ?? 0
        claridad = try c.decodeIfPresent(Float.self, forKey: .claridad) ?? 0
        vineteo = try c.decodeIfPresent(Float.self, forKey: .vineteo) ?? 0
        halation = try c.decodeIfPresent(Float.self, forKey: .halation) ?? 0
        bloom = try c.decodeIfPresent(Float.self, forKey: .bloom) ?? 0
    }

    public var isNeutral: Bool { self == Self.neutral }

    /// Cada efecto acotado a su rango (por ejemplo, al importar una receta compartida).
    public var clamped: LookEffects {
        func clamp(_ x: Float, _ low: Float) -> Float { x.isFinite ? min(max(x, low), 1) : 0 }
        return LookEffects(nitidez: clamp(nitidez, -1), claridad: clamp(claridad, -1), vineteo: clamp(vineteo, -1),
                           halation: clamp(halation, 0), bloom: clamp(bloom, 0))
    }
}

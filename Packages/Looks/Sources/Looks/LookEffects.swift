import Foundation

/// Lo de una receta que no entra en un LUT porque depende de los píxeles vecinos o de la
/// posición en el cuadro: nitidez, claridad (contraste local) y viñeteo.
///
/// Escala −1…1, 0 = sin efecto (una receta Ricoh de −4…+4 se divide por 4). En `looks.json` va
/// como `"effects": {"nitidez": …, "claridad": …, "vineteo": …}`; los que faltan valen 0.
public struct LookEffects: Sendable, Hashable, Codable {
    /// > 0 realza bordes finos, < 0 los suaviza.
    public var nitidez: Float
    /// > 0 más contraste local en medios tonos, < 0 más suave ("soñador").
    public var claridad: Float
    /// > 0 oscurece las esquinas, < 0 las aclara.
    public var vineteo: Float

    public static let neutral = LookEffects()

    public init(nitidez: Float = 0, claridad: Float = 0, vineteo: Float = 0) {
        self.nitidez = nitidez
        self.claridad = claridad
        self.vineteo = vineteo
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nitidez = try c.decodeIfPresent(Float.self, forKey: .nitidez) ?? 0
        claridad = try c.decodeIfPresent(Float.self, forKey: .claridad) ?? 0
        vineteo = try c.decodeIfPresent(Float.self, forKey: .vineteo) ?? 0
    }

    public var isNeutral: Bool { self == Self.neutral }

    /// Cada efecto acotado a −1…1 (por ejemplo, al importar una receta compartida).
    public var clamped: LookEffects {
        func clamp(_ x: Float) -> Float { x.isFinite ? min(max(x, -1), 1) : 0 }
        return LookEffects(nitidez: clamp(nitidez), claridad: clamp(claridad), vineteo: clamp(vineteo))
    }
}

import Foundation

/// Lo que la app le aplicó a una foto: receta, efectos, grano, intensidad, encuadre y bokeh. Se guarda con la
/// foto en Fotos (`PHAdjustmentData`) junto al original, así se puede reabrir y cambiar todo partiendo
/// del original, y "Revertir" en Fotos vuelve a la foto sin tocar.
public struct PhotoAdjustment: Codable, Sendable, Equatable {
    /// Identifica nuestros ajustes en Fotos; si cambia el formato, subir `formatVersion`.
    public static let formatIdentifier = "com.martinyernesto.cameraapp.receta"
    public static let formatVersion = "1"

    public var version = 1
    /// El Look tal como se aplicó (receta, LUT base, grano y efectos del momento).
    public var look: Look
    public var intensity: Float
    public var framing: Framing
    /// Focal equivalente del lente con que se sacó, para rehacer el recorte.
    public var lensFocalLength: Double
    /// Apertura simulada (modo A). nil = sin bokeh; también en las fotos guardadas antes de que existiera.
    public var bokeh: Bokeh?

    public init(look: Look, intensity: Float, framing: Framing, lensFocalLength: Double, bokeh: Bokeh? = nil) {
        self.look = look
        self.intensity = intensity
        self.framing = framing
        self.lensFocalLength = lensFocalLength
        self.bokeh = bokeh
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// nil si no son nuestros datos o no se pueden leer.
    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(PhotoAdjustment.self, from: data) else { return nil }
        self = decoded
    }
}

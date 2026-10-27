import Foundation

/// Looks creados en la app (recetas propias, cambios a los incluidos y `.cube` importados). Se
/// guardan en un JSON con el mismo formato de entrada que `looks.json`, así una receta propia se
/// puede pasar al catálogo tal cual. Un Look con el mismo id que uno incluido lo reemplaza.
public struct UserLookStore: Sendable {
    struct File: Codable {
        var version = 1
        var looks: [Look]
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Looks/user-looks.json`.
    public static var `default`: UserLookStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { UserLookStore(url: $0.appendingPathComponent("Looks/user-looks.json")) }
    }

    /// LUTs importados (`.lut` 64³), junto al JSON.
    public var lutDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("LUTs", isDirectory: true)
    }

    /// Importa un `.cube`: lo remuestrea a 64³, lo guarda en `lutDirectory` y devuelve el Look, con
    /// el LUT como base y la receta neutra encima (para retocarlo con los sliders). No lo agrega a la
    /// lista: eso lo hace quien llama, con `save`.
    public func importCube(_ text: String, name: String) throws -> Look {
        try importCube(data: Data(text.utf8), name: name)
    }

    /// Como `importCube(_:name:)`, con los bytes del archivo.
    public func importCube(data: Data, name: String) throws -> Look {
        let lut = try LUT3D(cubeData: data, size: LookCatalog.lutSize)
        let id = Self.newID()
        try FileManager.default.createDirectory(at: lutDirectory, withIntermediateDirectories: true)
        try lut.encoded().write(to: lutDirectory.appendingPathComponent(id + ".lut"), options: .atomic)
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LookShare.maxNameLength))
        return Look(id: id, name: trimmed.isEmpty ? "LUT importado" : trimmed, lut: id + ".lut", recipe: .neutral)
    }

    /// Borra el `.lut` importado de un Look si ningún otro de `remaining` lo usa.
    public func removeLUTFile(of look: Look, remaining: [Look]) {
        guard let file = look.lut, !remaining.contains(where: { $0.lut == file }) else { return }
        try? FileManager.default.removeItem(at: lutDirectory.appendingPathComponent(file))
    }

    /// Id nuevo para una receta propia; no choca con los del catálogo.
    public static func newID() -> String {
        "propia-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Sin archivo todavía: lista vacía.
    public func load() throws -> [Look] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).looks
    }

    public func save(_ looks: [Look]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(looks: looks)).write(to: url, options: .atomic)
    }
}

/// Texto para compartir una receta, como se comparten las recetas Ricoh (mensaje, nota, foro), y
/// para importarla pegándola.
public enum LookShare {
    public enum Error: Swift.Error, Equatable {
        /// El Look tiene un LUT base (un `.cube` importado): no entra en un texto.
        case notARecipe
        /// El texto no contiene una receta.
        case noRecipeFound
    }

    static let format = "camera.app/receta"
    static let maxNameLength = 40

    struct Payload: Codable {
        var formato: String?
        var version: Int?
        var name: String?
        var recipe: FilmRecipe
        var grain: Float?
        var effects: LookEffects?
    }

    /// Solo recetas sin LUT base: un `.cube` importado no entra en un texto.
    public static func text(for look: Look) throws -> String {
        guard let recipe = look.recipe, look.lut == nil else { throw Error.notARecipe }
        let payload = Payload(formato: format, version: 1, name: look.name, recipe: recipe, grain: look.grain,
                              effects: look.effects.flatMap { $0.isNeutral ? nil : $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(payload), as: UTF8.self)
    }

    /// Lee una receta de un texto pegado. Acepta texto alrededor del JSON (por ejemplo, el mensaje
    /// en el que vino) y también una entrada de `looks.json`. Los valores se acotan a los rangos del
    /// editor: el texto viene de afuera.
    public static func look(from text: String, id: String) throws -> Look {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(text[start...end].utf8))
        else { throw Error.noRecipeFound }
        let trimmed = String((payload.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        let grain = payload.grain.map { $0.isFinite ? min(max($0, 0), 1) : 0 } ?? 0
        let effects = payload.effects?.clamped
        return Look(id: id, name: trimmed.isEmpty ? "Receta importada" : trimmed,
                    recipe: payload.recipe.clamped, grain: grain, effects: effects?.isNeutral == true ? nil : effects)
    }
}

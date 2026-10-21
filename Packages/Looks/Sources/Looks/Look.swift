import Foundation
import Synchronization

/// Un Look: LUT 3D + parámetros sugeridos. Se describe en `looks.json` (versionado); los que crea
/// el usuario, con el mismo formato, en `UserLookStore`.
///
/// El LUT sale de una receta de película (`recipe`, se genera en el dispositivo). Un Look puede
/// tener además un LUT base (`lut`, por ejemplo un `.cube` importado): la receta se aplica encima.
public struct Look: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    /// Archivo `.lut` base (en el bundle o, para los importados, en `UserLookStore.lutDirectory`).
    public let lut: String?
    /// Receta de película; con `lut`, se aplica sobre la salida de ese LUT.
    public let recipe: FilmRecipe?
    /// Grano sugerido (0…1).
    public let grain: Float
    /// Nitidez, claridad y viñeteo: lo de la receta que no entra en un LUT.
    public let effects: LookEffects?

    public init(id: String, name: String, lut: String? = nil, recipe: FilmRecipe? = nil, grain: Float = 0,
                effects: LookEffects? = nil) {
        self.id = id
        self.name = name
        self.lut = lut
        self.recipe = recipe
        self.grain = grain
        self.effects = effects
    }

    /// Cambia cuando cambia el LUT del Look (por ejemplo, al editar una receta propia): sirve de
    /// clave para cachear texturas.
    public var lutKey: String {
        [id, lut, recipe?.stableHash].compactMap { $0 }.joined(separator: "-")
    }
}

/// Looks incluidos en el paquete (generados con `scripts/make_luts.py`).
public enum LookCatalog {
    struct Manifest: Decodable {
        let version: Int
        let lutSize: Int
        let looks: [Look]
    }

    public enum Error: Swift.Error, Equatable {
        /// El Look no tiene ni receta ni archivo `.lut`.
        case noLUT(String)
    }

    /// Tamaño de los LUTs que se generan desde una receta.
    public static let lutSize = 64

    /// LUTs ya generados en esta ejecución, por clave de caché.
    private static let memory = Mutex<[String: LUT3D]>([:])

    public static func bundled() throws -> [Look] {
        let url = try resource("looks.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).looks
    }

    /// Directorio por defecto del caché en disco de LUTs generados (Caches del sistema).
    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Looks", isDirectory: true)
    }

    /// LUT del Look. Con receta, lo genera (puede tardar: llamar fuera del main actor), sobre el LUT
    /// base si tiene uno, y lo cachea en memoria y en `cacheDirectory`; sin receta, lee el `.lut`.
    /// Los `.lut` se buscan primero en `userLUTDirectory` (importados) y después en el bundle.
    public static func lut(for look: Look, cacheDirectory: URL? = defaultCacheDirectory,
                           userLUTDirectory: URL? = UserLookStore.default?.lutDirectory) throws -> LUT3D {
        guard let recipe = look.recipe else {
            guard let file = look.lut else { throw Error.noLUT(look.id) }
            return try lutFile(file, userLUTDirectory: userLUTDirectory)
        }
        let key = cacheKey(id: look.id, recipe: recipe, lut: look.lut)
        if let cached = memory.withLock({ $0[key] }) { return cached }

        let file = cacheDirectory?.appendingPathComponent(key + ".lut")
        let lut: LUT3D
        if let file, let stored = try? LUT3D(contentsOf: file), stored.size == lutSize {
            lut = stored
        } else {
            let base = try look.lut.map { try lutFile($0, userLUTDirectory: userLUTDirectory) }
            lut = recipe.makeLUT(size: lutSize, base: base)
            if let file, let directory = cacheDirectory {
                // El caché es opcional: si no se puede escribir, se regenera la próxima vez.
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? lut.encoded().write(to: file, options: .atomic)
            }
        }
        memory.withLock { $0[key] = lut }
        return lut
    }

    /// id + LUT base + hash estable de la receta + versión del generador: cambiar cualquiera invalida
    /// el caché.
    static func cacheKey(id: String, recipe: FilmRecipe, lut: String? = nil) -> String {
        [id, lut, recipe.stableHash, "g\(FilmRecipe.generatorVersion)"].compactMap { $0 }.joined(separator: "-")
    }

    static func lutFile(_ name: String, userLUTDirectory: URL?) throws -> LUT3D {
        if let user = userLUTDirectory?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: user.path) {
            return try LUT3D(contentsOf: user)
        }
        return try LUT3D(contentsOf: resource(name))
    }

    static func resource(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "LUTs") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "LUTs/\(name)"])
        }
        return url
    }
}

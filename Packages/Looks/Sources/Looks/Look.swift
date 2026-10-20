import Foundation
import Synchronization

/// Un Look: LUT 3D + parámetros sugeridos. Se describe en `looks.json` (versionado); los que crea
/// el usuario, con el mismo formato, en `UserLookStore`.
///
/// El LUT sale de una receta de película (`recipe`, se genera en el dispositivo) o de un
/// archivo `.lut` precalculado (`lut`).
public struct Look: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    /// Nombre del archivo `.lut` dentro del bundle, para los Looks sin receta.
    public let lut: String?
    /// Receta de película; si está, tiene prioridad sobre `lut`.
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
        recipe.map { "\(id)-\($0.stableHash)" } ?? id
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

    /// LUT del Look. Con receta, lo genera (puede tardar: llamar fuera del main actor) y lo
    /// cachea en memoria y en `cacheDirectory`; sin receta, lee el `.lut` del bundle.
    public static func lut(for look: Look, cacheDirectory: URL? = defaultCacheDirectory) throws -> LUT3D {
        guard let recipe = look.recipe else {
            guard let file = look.lut else { throw Error.noLUT(look.id) }
            return try LUT3D(contentsOf: resource(file))
        }
        let key = cacheKey(id: look.id, recipe: recipe)
        if let cached = memory.withLock({ $0[key] }) { return cached }

        let file = cacheDirectory?.appendingPathComponent(key + ".lut")
        let lut: LUT3D
        if let file, let stored = try? LUT3D(contentsOf: file), stored.size == lutSize {
            lut = stored
        } else {
            lut = recipe.makeLUT(size: lutSize)
            if let file, let directory = cacheDirectory {
                // El caché es opcional: si no se puede escribir, se regenera la próxima vez.
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? lut.encoded().write(to: file, options: .atomic)
            }
        }
        memory.withLock { $0[key] = lut }
        return lut
    }

    /// id + hash estable de la receta + versión del generador: cambiar cualquiera invalida el caché.
    static func cacheKey(id: String, recipe: FilmRecipe) -> String {
        "\(id)-\(recipe.stableHash)-g\(FilmRecipe.generatorVersion)"
    }

    static func resource(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "LUTs") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "LUTs/\(name)"])
        }
        return url
    }
}

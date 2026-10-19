import Foundation

/// Un Look: LUT 3D + parámetros sugeridos. Se describe en `looks.json` (versionado).
public struct Look: Sendable, Identifiable, Hashable, Decodable {
    public let id: String
    public let name: String
    /// Nombre del archivo `.lut` dentro del bundle.
    public let lut: String
    /// Grano sugerido (0…1).
    public let grain: Float
}

/// Looks incluidos en el paquete (generados con `scripts/make_luts.py`).
public enum LookCatalog {
    struct Manifest: Decodable {
        let version: Int
        let lutSize: Int
        let looks: [Look]
    }

    public static func bundled() throws -> [Look] {
        let url = try resource("looks.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).looks
    }

    public static func lut(for look: Look) throws -> LUT3D {
        try LUT3D(contentsOf: resource(look.lut))
    }

    static func resource(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "LUTs") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "LUTs/\(name)"])
        }
        return url
    }
}

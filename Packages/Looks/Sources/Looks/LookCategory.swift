import Foundation
import simd

/// Color o blanco y negro, para separar los Looks en el selector.
public enum LookCategory: String, Sendable, CaseIterable, Identifiable {
    case color
    case monochrome

    public var id: String { rawValue }
}

extension LUT3D {
    /// Blanco y negro (también virado: sepia, selenio…): todos los colores salen con el mismo tono,
    /// aunque cambie el brillo. Se mira el tono de cada salida relativo a su luminancia.
    public var isMonochrome: Bool {
        let values = floatTexels
        let step = max(1, size / 8)
        var tints: [SIMD2<Float>] = []
        for b in stride(from: 0, to: size, by: step) {
            for g in stride(from: 0, to: size, by: step) {
                for r in stride(from: 0, to: size, by: step) {
                    let i = ((b * size + g) * size + r) * 4
                    let rgb = SIMD3(values[i], values[i + 1], values[i + 2])
                    let luma = (rgb * SIMD3(0.2126, 0.7152, 0.0722)).sum()
                    guard luma > 0.05 else { continue }
                    tints.append(SIMD2(rgb.x - luma, rgb.z - luma) / luma)
                }
            }
        }
        guard !tints.isEmpty else { return true }
        let mean = tints.reduce(SIMD2<Float>(), +) / Float(tints.count)
        return tints.allSatisfy { simd_length($0 - mean) < Self.monochromeTolerance }
    }

    /// Cuánto puede variar el tono (relativo a la luminancia) entre colores para seguir siendo
    /// blanco y negro.
    static let monochromeTolerance: Float = 0.06
}

extension LookCatalog {
    /// Color o blanco y negro. Con receta en blanco y negro, por la receta; si tiene un LUT base (un
    /// `.cube` importado), mirando el LUT. Lee archivos: llamar fuera del main actor.
    public static func category(of look: Look,
                                userLUTDirectory: URL? = UserLookStore.default?.lutDirectory) -> LookCategory {
        if let recipe = look.recipe, recipe.mono >= 0.5 { return .monochrome }
        guard let file = look.lut, let lut = try? lutFile(file, userLUTDirectory: userLUTDirectory) else {
            return .color
        }
        return lut.isMonochrome ? .monochrome : .color
    }
}

/// Orden del selector: Natural primero, después los favoritos y después el resto, cada grupo en el
/// orden de la lista.
public enum LookOrder {
    public static func arranged(_ looks: [Look], favorites: Set<String>, firstID: String = "natural") -> [Look] {
        let first = looks.filter { $0.id == firstID }
        let rest = looks.filter { $0.id != firstID }
        return first + rest.filter { favorites.contains($0.id) } + rest.filter { !favorites.contains($0.id) }
    }
}

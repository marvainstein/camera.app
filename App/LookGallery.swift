import Foundation
import Looks
import Metal
import Observation
import UIKit

/// Lo que el selector de Looks muestra de cada uno: miniatura sobre la foto de muestra, color o
/// blanco y negro, y si es favorito. Las miniaturas se generan en segundo plano, de a una.
@MainActor
@Observable
final class LookGallery {
    /// Ids de los Looks favoritos (se guardan en el teléfono).
    private(set) var favorites: Set<String>
    /// Color o blanco y negro, por `Look.lutKey`.
    private(set) var categories: [String: LookCategory] = [:]
    /// Miniaturas, por `thumbnailKey`.
    private(set) var thumbnails: [String: UIImage] = [:]

    private var task: Task<Void, Never>?
    private static let favoritesKey = "lookFavoritos"
    /// Foto de muestra (Arlet Padrón Benítez, Unsplash), 600 × 750.
    private let sample = SampleImage(UIImage(named: "Muestra")?.cgImage)

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
    }

    func isFavorite(_ look: Look) -> Bool {
        favorites.contains(look.id)
    }

    func toggleFavorite(_ look: Look) {
        if favorites.contains(look.id) {
            favorites.remove(look.id)
        } else {
            favorites.insert(look.id)
        }
        UserDefaults.standard.set(favorites.sorted(), forKey: Self.favoritesKey)
    }

    /// Mientras no se sabe (un `.cube` importado que todavía no se miró), color.
    func category(of look: Look) -> LookCategory {
        if let known = categories[look.lutKey] { return known }
        if let recipe = look.recipe, recipe.mono >= 0.5 { return .monochrome }
        return .color
    }

    func thumbnail(for look: Look) -> UIImage? {
        thumbnails[Self.thumbnailKey(look)]
    }

    /// Cambia con el LUT, el grano y los efectos: lo que se ve en la miniatura.
    static func thumbnailKey(_ look: Look) -> String {
        "\(look.lutKey)-\(look.grain)-\(String(describing: look.effects))"
    }

    /// Genera lo que falte (miniaturas y categorías) para estos Looks, en orden.
    func update(looks: [Look], renderer: LookRenderer) {
        let missing = looks.filter { thumbnails[Self.thumbnailKey($0)] == nil || categories[$0.lutKey] == nil }
        guard !missing.isEmpty else { return }
        task?.cancel()
        let sample = sample
        task = Task {
            for look in missing {
                guard !Task.isCancelled else { return }
                let result = await Task.detached(priority: .utility) {
                    Self.render(look, sample: sample, renderer: renderer)
                }.value
                categories[look.lutKey] = result.category
                if let image = result.image {
                    thumbnails[Self.thumbnailKey(look)] = UIImage(cgImage: image)
                }
            }
        }
    }

    private nonisolated static func render(_ look: Look, sample: SampleImage,
                                           renderer: LookRenderer) -> RenderedThumbnail {
        let category = LookCatalog.category(of: look)
        guard let image = sample.image,
              let lut = try? LookCatalog.lut(for: look),
              let texture = try? renderer.makeLUTTexture(lut)
        else { return RenderedThumbnail(category: category, image: nil) }
        let parameters = LookParameters(intensity: 1, grain: look.grain, effects: look.effects ?? .neutral)
        return RenderedThumbnail(category: category,
                                 image: try? renderer.render(image: image, lut: texture, parameters: parameters))
    }
}

/// `CGImage` es inmutable: se puede pasar entre hilos.
private struct SampleImage: @unchecked Sendable {
    let image: CGImage?

    init(_ image: CGImage?) {
        self.image = image
    }
}

private struct RenderedThumbnail: @unchecked Sendable {
    let category: LookCategory
    let image: CGImage?
}

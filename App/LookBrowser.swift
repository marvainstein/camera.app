import Looks
import SwiftUI

/// Selector de Looks: pestañas (favoritos, color, blanco y negro) y una tira de miniaturas sobre la
/// foto de muestra. Natural va primero y después los favoritos.
struct LookBrowser: View {
    enum Tab: Hashable {
        case favorites
        case category(LookCategory)
    }

    let model: CameraModel
    let onClose: () -> Void
    @State private var tab: Tab = .category(.color)

    private static let tileWidth: CGFloat = 78

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Button {
                    tab = .favorites
                } label: {
                    Image(systemName: tab == .favorites ? "star.fill" : "star")
                }
                .accessibilityLabel("Favoritos")
                Spacer()
                tabButton("Color", .category(.color))
                tabButton("Blanco y negro", .category(.monochrome))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cerrar")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(shownLooks) { look in
                            tile(look).id(look.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: Self.tileWidth * 1.25 + 36)
                .overlay {
                    if shownLooks.isEmpty {
                        Text(tab == .favorites ? "Tocá la estrella de un Look para sumarlo acá" : "No hay Looks")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if let id = model.selectedLookID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: tab) {
                    if let id = model.selectedLookID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if let look = model.selectedLook { tab = .category(model.gallery.category(of: look)) }
        }
    }

    /// Los de la pestaña, en el orden del selector (Natural, favoritos, el resto).
    private var shownLooks: [Look] {
        let gallery = model.gallery
        return model.arrangedLooks.filter { look in
            switch tab {
            case .favorites: gallery.isFavorite(look)
            case .category(let category): gallery.category(of: look) == category
            }
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button(title) { tab = value }
            .foregroundStyle(tab == value ? Color.white : Color.white.opacity(0.45))
    }

    private func tile(_ look: Look) -> some View {
        let selected = model.selectedLookID == look.id
        let favorite = model.gallery.isFavorite(look)
        return VStack(spacing: 6) {
            Button {
                model.select(look)
            } label: {
                thumbnail(look)
            }
            .overlay(alignment: .topLeading) {
                // La estrella: siempre en el elegido, y en los favoritos aunque no estén elegidos.
                if selected || favorite {
                    Button {
                        model.gallery.toggleFavorite(look)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.caption)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel(favorite ? "Quitar de favoritos" : "Agregar a favoritos")
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button {
                        model.edit(look)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel("Editar \(look.name)")
                }
            }
            .contextMenu { LookActions(model: model, look: look) }

            Text(look.name)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: Self.tileWidth)
        }
        .foregroundStyle(.white)
    }

    private func thumbnail(_ look: Look) -> some View {
        ZStack {
            Color.white.opacity(0.1)
            if let image = model.gallery.thumbnail(for: look) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.tileWidth, height: Self.tileWidth * 1.25)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white, lineWidth: model.selectedLookID == look.id ? 2 : 0)
        }
    }
}

/// Editar, duplicar, compartir, restaurar o borrar un Look (menú al mantener apretado).
struct LookActions: View {
    let model: CameraModel
    let look: Look

    var body: some View {
        Button("Editar \(look.name)", systemImage: "slider.horizontal.3") {
            model.select(look)
            model.edit(look)
        }
        Button("Duplicar y editar", systemImage: "plus.square.on.square") {
            model.select(look)
            model.duplicate(look)
        }
        if let text = model.shareText(for: look) {
            ShareLink("Compartir receta", item: text, preview: SharePreview(look.name))
        }
        if model.isModified(look) {
            Button("Restaurar original", systemImage: "arrow.uturn.backward") { model.restoreOriginal(look) }
        }
        if model.isUserLook(look) {
            Button("Borrar \(look.name)", systemImage: "trash", role: .destructive) { model.delete(look) }
        }
    }
}

/// Unos segundos después de elegir un Look: su nombre, intensidad y grano, sobre el visor.
struct LookInfoCard: View {
    let model: CameraModel

    var body: some View {
        if let look = model.selectedLook {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.name).font(.headline)
                    Text("Intensidad \(percent(model.intensity)) · Grano \(percent(model.grain))"
                         + (model.gallery.isFavorite(look) ? " · ★" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func percent(_ value: Float) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

import Looks
import SwiftUI

/// Editor de recetas: panel en la parte de abajo de la pantalla, con la foto entera arriba para ver
/// cada cambio en vivo.
struct RecipeEditor: View {
    @Bindable var model: CameraModel
    @State private var confirmsDelete = false

    /// El borrador, sin desenvolver a la fuerza: mientras el panel se va (después de guardar o
    /// cancelar) los sliders todavía lo leen y `model.draft` ya es nil.
    private var draft: Binding<LookDraft> {
        Binding(get: { model.draft ?? LookDraft() },
                set: { if model.draft != nil { model.draft = $0 } })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack {
            Button("Cancelar") { model.cancelEditing() }
            Spacer()
            Text(draft.wrappedValue.editingID == nil ? "Nueva receta" : "Editar receta")
                .font(.headline)
            Button {
                model.compareSplit = model.compareSplit == nil ? 0.5 : nil
            } label: {
                Image(systemName: model.compareSplit == nil ? "square.split.2x1" : "square.split.2x1.fill")
            }
            .accessibilityLabel(model.compareSplit == nil ? "Comparar antes y después" : "Dejar de comparar")
            Spacer()
            if draft.wrappedValue.editingID == nil {
                Button("Guardar") { model.saveDraft() }
                    .fontWeight(.semibold)
            } else {
                Menu("Guardar") {
                    Button("Guardar cambios") { model.saveDraft() }
                    Button("Guardar como nueva") { model.saveDraft(asNew: true) }
                }
                .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Nombre", text: draft.name)
                Toggle("Blanco y negro", isOn: Binding(
                    get: { draft.wrappedValue.recipe.mono != 0 },
                    set: { draft.wrappedValue.recipe.mono = $0 ? 1 : 0 }))
            }
            Section {
                RecipeSlider(title: "Grano", value: double(draft.grain), range: 0...1, neutral: 0)
                RecipeSlider(title: "Nitidez", value: double(draft.effects.nitidez), range: -1...1, neutral: 0)
                RecipeSlider(title: "Claridad", value: double(draft.effects.claridad), range: -1...1, neutral: 0)
                RecipeSlider(title: "Viñeteo", value: double(draft.effects.vineteo), range: -1...1, neutral: 0)
                RecipeSlider(title: "Halation", value: double(draft.effects.halation), range: 0...1, neutral: 0)
                RecipeSlider(title: "Bloom", value: double(draft.effects.bloom), range: 0...1, neutral: 0)
            } header: {
                Text("Efectos")
            } footer: {
                Text("Tocá el valor de un slider para volverlo a neutro.")
            }
            ForEach(FilmRecipe.Group.allCases) { group in
                Section(group.title) {
                    ForEach(FilmRecipe.parameters.filter { $0.group == group }) { parameter in
                        RecipeSlider(title: parameter.name,
                                     value: draft.recipe[dynamicMember: parameter.keyPath],
                                     range: parameter.range,
                                     neutral: FilmRecipe.neutral[keyPath: parameter.keyPath])
                    }
                }
            }
            Section {
                if let original = draft.wrappedValue.original {
                    Button("Volver al original") {
                        draft.wrappedValue = LookDraft(from: original, editingID: draft.wrappedValue.editingID)
                    }
                }
                if let text = model.shareText(for: draft.wrappedValue.look(id: "compartida")) {
                    ShareLink("Compartir receta", item: text,
                              preview: SharePreview(draft.wrappedValue.name.isEmpty ? "Receta" : draft.wrappedValue.name))
                }
                if let id = draft.wrappedValue.editingID, let look = model.userLooks.first(where: { $0.id == id }) {
                    Button("Borrar receta", role: .destructive) { confirmsDelete = true }
                        .confirmationDialog("¿Borrar \(look.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                            Button("Borrar", role: .destructive) {
                                model.cancelEditing()
                                model.delete(look)
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 36)
    }

    private func double(_ value: Binding<Float>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) })
    }
}

private struct RecipeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Button(value.formatted(.number.precision(.fractionLength(2)))) { value = neutral }
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value == neutral ? .secondary : .primary)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Vuelve a \(neutral.formatted())")
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

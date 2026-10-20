import Looks
import SwiftUI

/// Editor de recetas: un slider por parámetro, con el visor detrás mostrando el resultado en vivo.
struct RecipeEditor: View {
    @Bindable var model: CameraModel
    @State private var confirmsDelete = false

    var body: some View {
        NavigationStack {
            if let draft = Binding($model.draft) {
                form(draft)
                    .navigationTitle(draft.wrappedValue.editingID == nil ? "Nueva receta" : "Editar receta")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar(draft.wrappedValue) }
            }
        }
    }

    private func form(_ draft: Binding<LookDraft>) -> some View {
        Form {
            Section {
                TextField("Nombre", text: draft.name)
                Toggle("Blanco y negro", isOn: Binding(
                    get: { draft.wrappedValue.recipe.mono != 0 },
                    set: { draft.wrappedValue.recipe.mono = $0 ? 1 : 0 }))
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
                RecipeSlider(title: "Grano", value: double(draft.grain), range: 0...1, neutral: 0)
                RecipeSlider(title: "Nitidez", value: double(draft.effects.nitidez), range: -1...1, neutral: 0)
                RecipeSlider(title: "Claridad", value: double(draft.effects.claridad), range: -1...1, neutral: 0)
                RecipeSlider(title: "Viñeteo", value: double(draft.effects.vineteo), range: -1...1, neutral: 0)
            } header: {
                Text("Efectos")
            } footer: {
                Text("Tocá el valor de un slider para volverlo a neutro.")
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
    }

    @ToolbarContentBuilder
    private func toolbar(_ draft: LookDraft) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancelar") { model.cancelEditing() }
        }
        ToolbarItem(placement: .confirmationAction) {
            if draft.editingID == nil {
                Button("Guardar") { model.saveDraft() }
            } else {
                Menu("Guardar") {
                    Button("Guardar cambios") { model.saveDraft() }
                    Button("Guardar como nueva") { model.saveDraft(asNew: true) }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Button(value.formatted(.number.precision(.fractionLength(2)))) { value = neutral }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value == neutral ? .secondary : .primary)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Vuelve a \(neutral.formatted())")
            }
            Slider(value: $value, in: range)
        }
    }
}

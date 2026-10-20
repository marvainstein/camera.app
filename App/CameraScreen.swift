import CaptureCore
import Looks
import PhotosUI
import SwiftUI
import UIKit

struct CameraScreen: View {
    @State private var model = CameraModel()
    @State private var showsManual = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview = model.preview {
                MetalPreview(renderer: preview).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                statusBanner
                lookPicker
                lookSliders
                shutterButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task { await model.start() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.usePhoto(data)
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showsManual) {
            ManualControls(settings: $model.settings, limits: model.limits)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: isEditingRecipe) {
            RecipeEditor(model: model)
                .presentationDetents([.medium, .large])
                // El visor queda visible arriba para ver la receta en vivo.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
    }

    private var isEditingRecipe: Binding<Bool> {
        Binding(get: { model.draft != nil }, set: { if !$0 { model.cancelEditing() } })
    }

    // MARK: - Barra superior: P/A, formato, manual

    private var isAperturePriority: Binding<Bool> {
        Binding(
            get: { if case .aperturePriority = model.settings.program { true } else { false } },
            set: { model.settings.program = $0 ? .aperturePriority(fNumber: 2.8) : .program })
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("Modo", selection: isAperturePriority) {
                Text("P").tag(false)
                Text("A").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)

            if case .aperturePriority(let fNumber) = model.settings.program {
                Menu {
                    ForEach(CaptureSettings.apertureStops, id: \.self) { stop in
                        Button("f/\(stop.formatted())") { model.settings.program = .aperturePriority(fNumber: stop) }
                    }
                } label: {
                    Text("f/\(fNumber.formatted())").font(.callout.monospacedDigit())
                }
                .accessibilityHint("Apertura simulada")
            }

            Spacer()

            Picker("Formato", selection: $model.settings.photoFormat) {
                Text("HEIC").tag(PhotoFormat.heic)
                Text("RAW").tag(PhotoFormat.proRAW)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .disabled(model.capabilities?.isProRAWSupported != true)

            if model.photo != nil {
                Button {
                    model.closePhoto()
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Volver a la cámara")
            } else {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                }
                .accessibilityLabel("Probar con una foto")
            }

            Button {
                showsManual = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Controles manuales")
        }
    }

    // MARK: - Estado

    @ViewBuilder private var statusBanner: some View {
        let text: String? = if model.photo != nil {
            model.message ?? "Foto de la fototeca: el disparador guarda una copia con el Look"
        } else {
            switch model.status {
            case .starting, .running: model.message
            case .noCamera: "Sin cámara (simulador): Look aplicado sobre un patrón de prueba"
            case .denied: "Sin permiso de cámara. Activalo en Ajustes."
            case .failed(let reason): "Error: \(reason)"
            }
        }
        if let text {
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Looks

    private var lookPicker: some View {
        HStack(spacing: 8) {
            recipeMenu
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.looks) { look in
                        Button {
                            model.select(look)
                        } label: {
                            Label(look.name, systemImage: "person.fill")
                                .labelStyle(UserLookLabelStyle(isUserLook: model.isUserLook(look)))
                        }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(model.selectedLookID == look.id ? Color.white : Color.white.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(model.selectedLookID == look.id ? Color.black : Color.white)
                        .contextMenu { lookActions(look) }
                    }
                }
            }
        }
    }

    /// Crear, editar o pegar recetas.
    private var recipeMenu: some View {
        Menu {
            Button("Receta nueva", systemImage: "plus") { model.newRecipe() }
            if let look = model.selectedLook {
                lookActions(look)
            }
            Button("Pegar receta", systemImage: "doc.on.clipboard") {
                model.importRecipe(from: UIPasteboard.general.string ?? "")
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .padding(8)
                .background(Color.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("Recetas")
    }

    @ViewBuilder private func lookActions(_ look: Look) -> some View {
        if look.recipe != nil {
            Button(model.isUserLook(look) ? "Editar \(look.name)" : "Copiar y editar \(look.name)",
                   systemImage: "slider.horizontal.3") {
                model.select(look)
                model.edit(look)
            }
            if let text = model.shareText(for: look) {
                ShareLink("Compartir receta", item: text, preview: SharePreview(look.name))
            }
        }
        if model.isUserLook(look) {
            Button("Borrar \(look.name)", systemImage: "trash", role: .destructive) { model.delete(look) }
        }
    }

    private var lookSliders: some View {
        VStack(spacing: 4) {
            LabeledSlider(title: "Intensidad", value: $model.intensity)
            LabeledSlider(title: "Grano", value: $model.grain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var shutterButton: some View {
        Button {
            Task { await model.capture() }
        } label: {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .background(Circle().fill(model.isCapturing ? Color.gray : Color.white).padding(6))
                .frame(width: 72, height: 72)
        }
        .disabled((model.status != .running && model.photo == nil) || model.isCapturing)
        .accessibilityLabel(model.photo == nil ? "Disparar" : "Guardar copia con el Look")
    }
}

/// Las recetas propias llevan un iconito delante del nombre.
private struct UserLookLabelStyle: LabelStyle {
    let isUserLook: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if isUserLook { configuration.icon.imageScale(.small) }
            configuration.title
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Float

    var body: some View {
        HStack {
            Text(title).font(.caption).frame(width: 72, alignment: .leading)
            Slider(value: $value, in: 0...1)
            Text(value.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// ISO, obturación, compensación EV y balance de blancos.
private struct ManualControls: View {
    @Binding var settings: CaptureSettings
    let limits: ExposureLimits

    var body: some View {
        NavigationStack {
            Form {
                Section("Exposición") {
                    Toggle("ISO automático", isOn: optionalBinding(\.iso, default: limits.isoStops.first { $0 >= 100 } ?? limits.isoStops.first ?? 100))
                    if let iso = settings.iso {
                        Picker("ISO", selection: Binding(get: { iso }, set: { settings.iso = $0 })) {
                            ForEach(limits.isoStops, id: \.self) { Text($0.formatted()).tag($0) }
                        }
                    }
                    Toggle("Obturación automática",
                           isOn: optionalBinding(\.shutterSeconds, default: limits.shutterStops.first { $0 <= 1.0 / 125 } ?? 0.008))
                    if let shutter = settings.shutterSeconds {
                        Picker("Obturación", selection: Binding(get: { shutter }, set: { settings.shutterSeconds = $0 })) {
                            ForEach(limits.shutterStops, id: \.self) { Text(Self.format(shutter: $0)).tag($0) }
                        }
                    }
                    if settings.iso == nil && settings.shutterSeconds == nil {
                        VStack(alignment: .leading) {
                            Text("Compensación: \(settings.exposureBias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) EV")
                            Slider(value: $settings.exposureBias, in: max(-3, limits.biasRange.lowerBound)...min(3, limits.biasRange.upperBound),
                                   step: 1.0 / 3)
                        }
                    }
                }
                Section("Balance de blancos") {
                    Toggle("Automático", isOn: Binding(
                        get: { settings.whiteBalance == .auto },
                        set: { settings.whiteBalance = $0 ? .auto : .manual(temperature: 5500, tint: 0) }))
                    if case .manual(let temperature, let tint) = settings.whiteBalance {
                        VStack(alignment: .leading) {
                            Text("Temperatura: \(Int(temperature)) K")
                            Slider(value: Binding(get: { temperature },
                                                  set: { settings.whiteBalance = .manual(temperature: $0, tint: tint) }),
                                   in: 2500...10000, step: 100)
                            Text("Tinte: \(Int(tint))")
                            Slider(value: Binding(get: { tint },
                                                  set: { settings.whiteBalance = .manual(temperature: temperature, tint: $0) }),
                                   in: -50...50, step: 1)
                        }
                    }
                }
            }
            .navigationTitle("Manual")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Toggle "automático": encendido = `nil`, apagado = valor por defecto.
    private func optionalBinding<T>(_ keyPath: WritableKeyPath<CaptureSettings, T?>, default value: T) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] == nil },
                set: { settings[keyPath: keyPath] = $0 ? nil : value })
    }

    static func format(shutter seconds: Double) -> String {
        seconds >= 1 ? "\(seconds.formatted()) s" : "1/\(Int((1 / seconds).rounded()))"
    }
}

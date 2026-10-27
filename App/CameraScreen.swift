import CaptureCore
import Looks
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraScreen: View {
    @State private var model = CameraModel()
    @State private var showsManual = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importsCube = false
    /// Panel de Looks abierto.
    @State private var showsLookBrowser = false
    /// La tarjeta con los datos del Look (unos segundos después de elegirlo).
    @State private var showsLookCard = false
    /// Destello del disparo: el visor se oscurece y vuelve.
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                    .padding(.horizontal, 16)
                if let preview = model.preview {
                    // El visor muestra la foto entera (cámara, foto abierta o editor), entre los controles:
                    // así el formato y el recorte por focal se ven como van a salir.
                    viewfinder(preview)
                } else {
                    Spacer()
                }
                Group {
                    if model.draft != nil {
                        RecipeEditor(model: model)
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                    } else {
                        if showsLookBrowser {
                            LookBrowser(model: model) { withAnimation(.snappy) { showsLookBrowser = false } }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            lookBar
                        }
                        shutterRow
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
        }
        .task { await model.start() }
        .onChange(of: model.shutterCount) {
            // Oscurece de golpe y vuelve en un cuarto de segundo, como el obturador de la cámara de Apple.
            flashOpacity = 0.9
            withAnimation(.easeOut(duration: 0.25)) { flashOpacity = 0 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.shutterCount)
        .task(id: model.selectedLookID) {
            // Al elegir un Look (no al abrir la app), su tarjeta unos segundos.
            guard model.selectedLookID != nil, model.status == .running || model.photo != nil else { return }
            withAnimation { showsLookCard = true }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { showsLookCard = false }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // Se edita la misma foto (sin perder el original); si no se puede (sin acceso completo a
                // Fotos), se abre una copia.
                var editing = false
                if let id = item.itemIdentifier {
                    editing = await model.openPhotoForEditing(localIdentifier: id)
                }
                if !editing, let data = try? await item.loadTransferable(type: Data.self) {
                    await model.usePhoto(data)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $importsCube,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .zip, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.importCubes(at: urls) }
            }
        }
        .sheet(isPresented: $showsManual) {
            ManualControls(settings: $model.settings, limits: model.limits)
                .presentationDetents([.medium, .large])
        }
    }

    /// El visor con lo que va encima: nivel e histograma (cámara en vivo), avisos y la tarjeta del Look
    /// abajo, y el destello del disparo.
    private func viewfinder(_ preview: PreviewRenderer) -> some View {
        comparablePreview(preview)
            .overlay {
                if model.status == .running, model.photo == nil, model.draft == nil {
                    ViewfinderHUD(model: model)
                }
            }
            .overlay(alignment: .bottom) {
                if model.draft == nil {
                    VStack(spacing: 8) {
                        if showsLookCard {
                            LookInfoCard(model: model)
                                .transition(.opacity)
                        }
                        statusBanner
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                Color.black
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: model.showsWholeFrame ? 12 : 0))
    }

    /// El visor; al comparar, arrastrar mueve la línea de antes/después.
    private func comparablePreview(_ preview: PreviewRenderer) -> some View {
        MetalPreview(renderer: preview, gestures: PreviewGestures(
            onTap: { point, size in model.focus(atViewPoint: point, viewSize: size) },
            onDrag: { model.dragBrightness(by: $0) },
            shouldBeginDrag: { model.shouldBeginBrightnessDrag(velocity: $0) }))
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let x = value.location.x / max(geometry.size.width, 1)
                            model.compareSplit = Float(min(max(x, 0.02), 0.98))
                        })
                }
                .allowsHitTesting(model.compareSplit != nil)
            }
            .overlay {
                if model.guides.grid, model.draft == nil {
                    GeometryReader { geometry in
                        if let rect = preview.viewRect(forImageRect: model.frameRect, viewSize: geometry.size) {
                            GridOverlay(rect: rect)
                        }
                    }
                }
            }
            .overlay {
                if model.showsFocusSquare {
                    FocusOverlay(model: model)
                }
            }
            .overlay(alignment: .top) {
                if model.compareSplit != nil {
                    HStack {
                        Text("Antes")
                        Spacer()
                        Text("Después")
                    }
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Barra superior: P/A, formato, manual

    private var isAperturePriority: Binding<Bool> {
        Binding(
            get: { if case .aperturePriority = model.settings.program { true } else { false } },
            set: { model.settings.program = $0 ? .aperturePriority(fNumber: 2.8) : .program })
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("Modo", selection: isAperturePriority) {
                Text("P").tag(false)
                Text("A").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 84)

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

            flashButton

            formatMenu

            framingMenu

            guidesMenu

            Button {
                showsManual = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Controles manuales")
        }
    }

    /// Flash: cada toque pasa al siguiente (apagado → automático → siempre). Arranca apagado.
    @ViewBuilder private var flashButton: some View {
        if model.capabilities?.hasFlash == true, model.photo == nil {
            let flash = model.settings.flash
            let icon = switch flash {
            case .off: "bolt.slash"
            case .auto: "bolt.badge.automatic"
            case .on: "bolt.fill"
            }
            let label = switch flash {
            case .off: "Flash apagado"
            case .auto: "Flash automático"
            case .on: "Flash siempre"
            }
            Button {
                model.settings.flash = flash.next
            } label: {
                Image(systemName: icon)
                    .foregroundStyle(flash == .on ? Color.yellow : Color.accentColor)
            }
            .accessibilityLabel(label)
        }
    }

    /// Cuadrícula, nivel e histograma del visor.
    private var guidesMenu: some View {
        Menu {
            Toggle("Cuadrícula", systemImage: "squareshape.split.3x3", isOn: $model.guides.grid)
            Toggle("Nivel", systemImage: "level", isOn: $model.guides.level)
            Toggle("Histograma", systemImage: "chart.bar.xaxis", isOn: $model.guides.histogram)
        } label: {
            Image(systemName: "squareshape.split.3x3")
        }
        .accessibilityLabel("Guías del visor")
    }

    /// Qué guarda cada toma: RAW + JPG por defecto.
    private var formatMenu: some View {
        let rawAvailable = model.capabilities?.isRAWSupported ?? false
        return Menu {
            ForEach(PhotoFormat.allCases) { format in
                Button {
                    model.settings.photoFormat = format
                } label: {
                    checkmarkLabel(format.rawValue, selected: model.settings.photoFormat == format)
                }
                .disabled(format.includesRAW && !rawAvailable)
            }
            if model.capabilities?.isProRAWSupported == false && rawAvailable {
                Text("En este iPhone el RAW es el del sensor, sin el procesado de Apple (ProRAW).")
            }
        } label: {
            Text(model.settings.photoFormat.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15), in: Capsule())
        }
        .accessibilityLabel("Formato: \(model.settings.photoFormat.rawValue)")
    }

    /// Recorte por focal y formato, como el modo crop de las compactas.
    private var framingMenu: some View {
        let lens = model.lensFocalLength
        let focal = model.framing.focalLength.map { Int($0.rounded()) } ?? Int(lens.rounded())
        return Menu {
            Section("Focal") {
                Button {
                    model.framing.focalLength = nil
                } label: {
                    checkmarkLabel("Lente (\(Int(lens.rounded())) mm)", selected: model.framing.focalLength == nil)
                }
                ForEach(Framing.focalLengths, id: \.self) { length in
                    Button {
                        model.framing.focalLength = length
                    } label: {
                        checkmarkLabel("\(Int(length)) mm", selected: model.framing.focalLength == length)
                    }
                    .disabled(length <= lens + 0.5)
                }
            }
            Section("Formato") {
                ForEach(Framing.Aspect.allCases) { aspect in
                    Button {
                        model.framing.aspect = aspect
                    } label: {
                        checkmarkLabel(aspect.rawValue, selected: model.framing.aspect == aspect)
                    }
                }
            }
        } label: {
            Text("\(focal) · \(model.framing.aspect.rawValue)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(model.framing.isFullFrame ? 0.15 : 0.35), in: Capsule())
        }
        .accessibilityLabel("Encuadre: \(focal) milímetros, formato \(model.framing.aspect.rawValue)")
    }

    @ViewBuilder private func checkmarkLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Estado

    @ViewBuilder private var statusBanner: some View {
        let text: String? = if model.photo != nil {
            model.message ?? (model.editingPhoto == nil
                ? "Foto de la fototeca: el disparador guarda una copia con el Look"
                : "Editando la foto: el disparador guarda los cambios (el original queda)")
        } else {
            switch model.status {
            case .starting, .running: model.message
            case .noCamera: "Sin cámara (simulador): Look aplicado sobre un patrón de prueba"
            case .denied: "Sin permiso de cámara. Activalo en Ajustes."
            case .failed(let reason): "Error: \(reason)"
            }
        }
        if let text {
            HStack(spacing: 8) {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                }
                Text(text)
            }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Looks

    /// La varita (recetas) a la izquierda y, a la derecha, el Look actual: al tocarlo se abre el panel.
    private var lookBar: some View {
        HStack(spacing: 8) {
            recipeMenu
            Spacer()
            Button {
                withAnimation(.snappy) { showsLookBrowser = true }
            } label: {
                HStack(spacing: 8) {
                    if let look = model.selectedLook, let image = model.gallery.thumbnail(for: look) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 35)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(model.selectedLook?.name ?? "Looks")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15), in: Capsule())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Look: \(model.selectedLook?.name ?? "ninguno"). Ver todos")
        }
    }

    /// Crear, editar o pegar recetas.
    private var recipeMenu: some View {
        Menu {
            Button("Receta nueva", systemImage: "plus") { model.newRecipe() }
            if let look = model.selectedLook {
                LookActions(model: model, look: look)
            }
            Button("Pegar receta", systemImage: "doc.on.clipboard") {
                model.importRecipe(from: UIPasteboard.general.string ?? "")
            }
            Button("Importar LUTs (.cube o .zip)…", systemImage: "square.and.arrow.down") { importsCube = true }
        } label: {
            Image(systemName: "wand.and.stars")
                .padding(8)
                .background(Color.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("Recetas")
    }

    /// Fototeca a la izquierda del disparador, comparar a la derecha (como la app de Cámara).
    private var shutterRow: some View {
        HStack {
            Group {
                if model.photo != nil {
                    Button {
                        model.closePhoto()
                    } label: {
                        Image(systemName: "camera")
                    }
                    .accessibilityLabel("Volver a la cámara")
                } else {
                    let label = LastPhotoLabel(thumbnail: model.lastPhotoThumbnail)
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        label
                    }
                    .accessibilityLabel(model.lastPhotoThumbnail == nil ? "Abrir una foto"
                                        : "Abrir una foto (la última que sacaste está acá)")
                }
            }
            .font(.title2)
            .frame(width: 56, height: 56)
            .background(Color.white.opacity(0.15), in: Circle())

            Spacer()
            shutterButton
            Spacer()

            Button {
                model.compareSplit = model.compareSplit == nil ? 0.5 : nil
            } label: {
                Image(systemName: model.compareSplit == nil ? "square.split.2x1" : "square.split.2x1.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(model.compareSplit == nil ? 0.15 : 0.35), in: Circle())
            }
            .accessibilityLabel(model.compareSplit == nil ? "Comparar antes y después" : "Dejar de comparar")
        }
        .foregroundStyle(.white)
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
        .accessibilityLabel(model.photo == nil ? "Disparar"
                            : model.editingPhoto == nil ? "Guardar copia con el Look" : "Guardar cambios en la foto")
    }
}

struct LabeledSlider: View {
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

/// La última foto (si ya se sacó una) o el ícono de la fototeca; al llegar una foto nueva, un pequeño
/// salto.
private struct LastPhotoLabel: View, @unchecked Sendable {
    let thumbnail: CGImage?

    var body: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                .keyframeAnimator(initialValue: 1.0, trigger: thumbnail) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(1.18, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.3)
                }
        } else {
            Image(systemName: "photo.on.rectangle")
        }
    }
}

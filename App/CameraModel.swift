import CaptureCore
import Looks
import Metal
import Observation

/// Receta en edición. Mientras existe, el preview muestra el borrador en vez del Look elegido.
struct LookDraft: Equatable {
    var name: String
    var recipe: FilmRecipe
    var grain: Float
    var effects: LookEffects
    /// Receta propia que se está editando; `nil` si el borrador sale de un Look incluido o de cero
    /// (al guardar se crea una nueva).
    let editingID: String?
    /// Como estaba al abrir el editor, para "Volver al original".
    let original: Look?

    init(from look: Look, editingID: String?) {
        name = editingID == nil ? "\(look.name) (mía)" : look.name
        recipe = look.recipe ?? .neutral
        grain = look.grain
        effects = look.effects ?? .neutral
        self.editingID = editingID
        original = look
    }

    init() {
        name = "Receta nueva"
        recipe = .neutral
        grain = 0
        effects = .neutral
        editingID = nil
        original = nil
    }

    func look(id: String) -> Look {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Look(id: id, name: trimmed.isEmpty ? "Receta propia" : trimmed, recipe: recipe, grain: grain,
                    effects: effects.isNeutral ? nil : effects)
    }
}

@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable {
        case starting
        case running
        /// Sin cámara (simulador): se muestra el patrón de prueba.
        case noCamera
        case denied
        case failed(String)
    }

    private(set) var status = Status.starting
    /// Looks incluidos y, después, las recetas propias.
    private(set) var looks: [Look] = []
    private var bundledLooks: [Look] = []
    private(set) var userLooks: [Look] = []
    private(set) var capabilities: CameraCapabilities?
    private(set) var isCapturing = false
    private(set) var message: String?
    /// Foto de la fototeca para probar Looks: mientras está, el visor la muestra en vez de la cámara
    /// y el disparador guarda una copia con el Look.
    private(set) var photo: Data?

    var selectedLookID: String? { didSet { loadSelectedLUT(); updatePreview() } }
    var intensity: Float = 1 { didSet { updatePreview() } }
    var grain: Float = 0 { didSet { updatePreview() } }
    /// Efectos del Look elegido.
    private(set) var effects = LookEffects.neutral
    /// Comparar antes/después: posición de la línea (0…1) o nil.
    var compareSplit: Float? { didSet { updatePreview() } }
    /// Foto de la fototeca o editor abierto: se muestra la imagen entera en vez de llenar la pantalla.
    var showsWholeFrame: Bool { photo != nil || draft != nil }
    /// Receta abierta en el editor.
    var draft: LookDraft? {
        didSet {
            if draft?.recipe != oldValue?.recipe { scheduleDraftLUT() }
            updatePreview()
        }
    }
    var settings = CaptureSettings() { didSet { if settings != oldValue { applySettings() } } }

    let preview: PreviewRenderer?
    private let camera = CameraController()
    private let userStore = UserLookStore.default
    /// Texturas de LUT ya cargadas, por `Look.lutKey`. Se cargan al elegir cada Look.
    private var lutTextures: [String: MTLTexture] = [:]
    private var loadingLUTs: Set<String> = []
    /// LUT del borrador: primero uno chico mientras se mueven los sliders, después el de 64³.
    private var draftTexture: MTLTexture?
    private var draftTask: Task<Void, Never>?
    /// Tamaño del LUT de vista previa del editor: se genera en milisegundos.
    private static let draftLUTSize = 25

    /// Límites para la UI cuando todavía no hay cámara (o en el simulador).
    var limits: ExposureLimits {
        capabilities?.limits ?? ExposureLimits(isoRange: 32...3200, shutterRange: (1.0 / 8000)...1, biasRange: -3...3)
    }

    var selectedLook: Look? { looks.first { $0.id == selectedLookID } }

    init() {
        preview = try? PreviewRenderer(looks: LookRenderer())
    }

    func start() async {
        guard let preview else {
            status = .failed("Metal no disponible")
            return
        }
        loadLooks()

        guard CameraController.isCameraAvailable else {
            preview.fallback = try? preview.looks.makeTexture(rgba8: TestPattern.rgba8(), width: 1080, height: 1920)
            status = .noCamera
            return
        }
        guard await CameraController.requestAccess() else {
            status = .denied
            return
        }
        do {
            camera.setFrameHandler { [preview] frame in preview.enqueue(frame) }
            capabilities = try await camera.configure()
            camera.start()
            status = .running
        } catch {
            status = .failed(String(describing: error))
        }
    }

    private func loadLooks() {
        do {
            bundledLooks = try LookCatalog.bundled()
        } catch {
            message = "No se pudieron cargar los Looks: \(error)"
        }
        do {
            userLooks = try userStore?.load() ?? []
        } catch {
            message = "No se pudieron cargar tus recetas: \(error)"
        }
        looks = bundledLooks + userLooks
        if let first = looks.first(where: { $0.id != "identidad" }) ?? looks.first {
            select(first)
        }
    }

    func select(_ look: Look) {
        selectedLookID = look.id
        grain = look.grain
        effects = look.effects ?? .neutral
        updatePreview()
    }

    func isUserLook(_ look: Look) -> Bool {
        userLooks.contains { $0.id == look.id }
    }

    /// Genera (receta) o lee (.lut) el LUT del Look elegido fuera del main actor y cachea la
    /// textura. Mientras tanto el preview sigue con el LUT anterior.
    private func loadSelectedLUT() {
        guard let look = selectedLook, let renderer = preview?.looks else { return }
        let key = look.lutKey
        guard lutTextures[key] == nil, !loadingLUTs.contains(key) else { return }
        loadingLUTs.insert(key)
        Task {
            defer { loadingLUTs.remove(key) }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    LoadedTexture(texture: try renderer.makeLUTTexture(LookCatalog.lut(for: look)))
                }.value
                lutTextures[key] = loaded.texture
                updatePreview()
            } catch {
                message = "No se pudo cargar \(look.name): \(error)"
                if selectedLookID == look.id { preview?.lut = nil }
            }
        }
    }

    /// Textura del Look elegido, si ya está cargada.
    private var selectedTexture: MTLTexture? {
        selectedLook.flatMap { lutTextures[$0.lutKey] }
    }

    private func updatePreview() {
        preview?.contentMode = showsWholeFrame ? .aspectFit : .aspectFill
        let split = compareSplit ?? 0
        if let draft {
            if let draftTexture { preview?.lut = draftTexture }
            preview?.parameters = LookParameters(intensity: intensity, grain: draft.grain, effects: draft.effects,
                                                 split: split)
            return
        }
        if let texture = selectedTexture {
            preview?.lut = texture
        } else if selectedLookID == nil {
            preview?.lut = nil
        }
        preview?.parameters = LookParameters(intensity: intensity, grain: grain, effects: effects, split: split)
    }

    // MARK: - Editor de recetas

    /// Abre el editor sobre un Look: si es una receta propia se edita; si es uno incluido, se
    /// edita una copia. Los Looks de `.lut` arrancan de la receta neutra.
    func edit(_ look: Look) {
        draft = LookDraft(from: look, editingID: isUserLook(look) ? look.id : nil)
    }

    func newRecipe() {
        draft = LookDraft()
    }

    func cancelEditing() {
        draft = nil
    }

    /// Guarda el borrador como receta propia (la misma que se editaba o una nueva) y la elige.
    func saveDraft(asNew: Bool = false) {
        guard let draft else { return }
        let id = (asNew ? nil : draft.editingID) ?? UserLookStore.newID()
        let look = draft.look(id: id)
        if let index = userLooks.firstIndex(where: { $0.id == id }) {
            userLooks[index] = look
        } else {
            userLooks.append(look)
        }
        guard persistUserLooks() else { return }
        if let draftTexture, draftTexture.width == LookCatalog.lutSize {
            lutTextures[look.lutKey] = draftTexture
        }
        self.draft = nil
        select(look)
        message = "Guardada: \(look.name)"
    }

    func delete(_ look: Look) {
        guard isUserLook(look) else { return }
        userLooks.removeAll { $0.id == look.id }
        guard persistUserLooks() else { return }
        if selectedLookID == look.id, let first = looks.first(where: { $0.id != "identidad" }) ?? looks.first {
            select(first)
        }
        message = "Borrada: \(look.name)"
    }

    /// Importa una receta compartida como texto (por ejemplo, desde el portapapeles).
    func importRecipe(from text: String) {
        do {
            let look = try LookShare.look(from: text, id: UserLookStore.newID())
            userLooks.append(look)
            guard persistUserLooks() else { return }
            select(look)
            message = "Importada: \(look.name)"
        } catch {
            message = "No encontré una receta en el texto copiado"
        }
    }

    func shareText(for look: Look) -> String? {
        try? LookShare.text(for: look)
    }

    /// Guarda las recetas propias y actualiza la lista; si no se puede, vuelve a leer el archivo.
    private func persistUserLooks() -> Bool {
        do {
            guard let userStore else { throw CocoaError(.fileNoSuchFile) }
            try userStore.save(userLooks)
            looks = bundledLooks + userLooks
            return true
        } catch {
            message = "No se pudo guardar: \(error)"
            userLooks = (try? userStore?.load()) ?? userLooks
            looks = bundledLooks + userLooks
            return false
        }
    }

    /// Genera el LUT del borrador: uno chico enseguida y, si los sliders se quedan quietos, el de
    /// 64³. Cada cambio cancela lo pendiente del anterior.
    private func scheduleDraftLUT() {
        draftTask?.cancel()
        guard let recipe = draft?.recipe, let renderer = preview?.looks else {
            draftTask = nil
            draftTexture = nil
            updatePreview()
            return
        }
        draftTask = Task {
            for size in [Self.draftLUTSize, LookCatalog.lutSize] {
                if size == LookCatalog.lutSize {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard !Task.isCancelled else { return }
                let loaded = try? await Task.detached(priority: .userInitiated) {
                    LoadedTexture(texture: try renderer.makeLUTTexture(recipe.makeLUT(size: size)))
                }.value
                guard let loaded, !Task.isCancelled else { return }
                draftTexture = loaded.texture
                updatePreview()
            }
        }
    }

    private func applySettings() {
        guard status == .running else { return }
        let settings = settings
        Task {
            do {
                try await camera.apply(settings)
            } catch {
                message = "No se pudo aplicar: \(error)"
            }
        }
    }

    // MARK: - Foto de la fototeca

    /// Muestra la foto en el visor (decodificada fuera del main actor).
    func usePhoto(_ data: Data) async {
        guard let renderer = preview?.looks else { return }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                LoadedTexture(texture: try renderer.makePreviewTexture(photo: data))
            }.value
            preview?.still = loaded.texture
            photo = data
            message = nil
            updatePreview()
        } catch {
            message = "No se pudo abrir esa foto"
        }
    }

    /// Vuelve a la cámara (o al patrón de prueba).
    func closePhoto() {
        photo = nil
        preview?.still = nil
        updatePreview()
    }

    /// Guarda en Fotos una copia de la foto elegida con el Look, los efectos y el grano.
    private func savePhotoWithLook(_ data: Data) async {
        guard !isCapturing, let preview else { return }
        guard let lut = selectedTexture else {
            message = "Esperá a que cargue el Look"
            return
        }
        isCapturing = true
        defer { isCapturing = false }
        let job = BakeJob(renderer: preview.looks, lut: lut,
                          parameters: LookParameters(intensity: intensity, grain: grain, effects: effects,
                                                     seed: .random(in: 0...UInt32.max)))
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try job.renderer.renderPhoto(data, lut: job.lut, parameters: job.parameters)
            }.value
            try await PhotoLibrary.save(processed: processed, raw: nil)
            message = "Copia guardada con \(selectedLook?.name ?? "el Look")"
        } catch {
            message = "No se pudo guardar: \(error)"
        }
    }

    func capture() async {
        if let photo {
            await savePhotoWithLook(photo)
            return
        }
        guard status == .running, !isCapturing, let preview else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            var photo = try await camera.capturePhoto(settings: settings)
            if let processed = photo.processed, let lut = selectedTexture {
                let job = BakeJob(renderer: preview.looks, lut: lut,
                                  parameters: LookParameters(intensity: intensity, grain: grain, effects: effects,
                                                             seed: .random(in: 0...UInt32.max)))
                photo.processed = try await Task.detached(priority: .userInitiated) {
                    try job.renderer.renderPhoto(processed, lut: job.lut, parameters: job.parameters)
                }.value
            }
            try await PhotoLibrary.save(processed: photo.processed, raw: photo.raw)
            message = photo.raw == nil ? "Guardada (HEIC)" : "Guardada (HEIC + ProRAW)"
        } catch {
            message = "Error al capturar: \(error)"
        }
    }
}

/// Textura recién subida desde una tarea de fondo. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct LoadedTexture: @unchecked Sendable {
    let texture: MTLTexture
}

/// Lo necesario para hornear el Look fuera del main actor. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct BakeJob: @unchecked Sendable {
    let renderer: LookRenderer
    let lut: MTLTexture
    let parameters: LookParameters
}

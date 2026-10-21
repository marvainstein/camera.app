import CaptureCore
import Looks
import Metal
import Observation
import UniformTypeIdentifiers

/// Receta en edición. Mientras existe, el preview muestra el borrador en vez del Look elegido.
struct LookDraft: Equatable {
    var name: String
    var recipe: FilmRecipe
    var grain: Float
    var effects: LookEffects
    /// LUT base (un `.cube` importado), que se conserva al guardar.
    let lut: String?
    /// Look que se está editando (incluido o propio): al guardar se reemplaza. `nil` = receta nueva
    /// o copia (al guardar se crea otra).
    let editingID: String?
    /// Como estaba al abrir el editor, para "Volver al original".
    let original: Look?

    init(from look: Look, editingID: String?) {
        name = editingID == nil ? "\(look.name) (copia)" : look.name
        recipe = look.recipe ?? .neutral
        grain = look.grain
        effects = look.effects ?? .neutral
        lut = look.lut
        self.editingID = editingID
        original = look
    }

    init() {
        name = "Receta nueva"
        recipe = .neutral
        grain = 0
        effects = .neutral
        lut = nil
        editingID = nil
        original = nil
    }

    func look(id: String) -> Look {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Look(id: id, name: trimmed.isEmpty ? "Receta propia" : trimmed, lut: lut, recipe: recipe, grain: grain,
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
    /// Foto de la fototeca para probar Looks: mientras está, el visor la muestra en vez de la cámara.
    /// El disparador guarda los cambios en la misma foto (`editingPhoto`) o, si no se pudo abrir para
    /// editar, una copia con el Look.
    private(set) var photo: Data?
    /// La foto de Fotos que se está editando, con su original y los ajustes guardados.
    private(set) var editingPhoto: PhotoLibrary.EditablePhoto?

    var selectedLookID: String? { didSet { loadSelectedLUT(); updatePreview() } }
    var intensity: Float = 1 { didSet { updatePreview() } }
    var grain: Float = 0 { didSet { updatePreview() } }
    /// Efectos del Look elegido.
    private(set) var effects = LookEffects.neutral
    /// Recorte por focal y formato: marco en el visor, foto recortada al guardar.
    var framing = Framing() { didSet { updatePreview() } }
    /// Focal equivalente del lente de la foto de la fototeca (de su EXIF).
    private var photoFocalLength: Double?
    /// Focal equivalente del lente que saca (o sacó) la imagen del visor.
    var lensFocalLength: Double {
        if photo != nil { return photoFocalLength ?? 24 }
        return capabilities?.equivalentFocalLength ?? 24
    }
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
    /// LUT base del Look en edición (un `.cube` importado), o nil.
    private var draftBase: LUT3D?
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
            updatePreview()
            return
        }
        guard await CameraController.requestAccess() else {
            status = .denied
            return
        }
        do {
            camera.setFrameHandler { [preview] frame in preview.enqueue(frame) }
            capabilities = try await camera.configure()
            // Sin RAW en este iPhone: el mismo formato sin RAW.
            if capabilities?.isRAWSupported == false, settings.photoFormat.includesRAW {
                settings.photoFormat = settings.photoFormat.withoutRAW
            }
            camera.start()
            status = .running
            updatePreview()
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
        rebuildLooks()
        if let first = looks.first(where: { $0.id != "natural" }) ?? looks.first {
            select(first)
        }
    }

    /// Los incluidos (con los cambios del usuario encima) y después los propios.
    private func rebuildLooks() {
        let bundledIDs = Set(bundledLooks.map(\.id))
        looks = bundledLooks.map { look in userLooks.first { $0.id == look.id } ?? look }
            + userLooks.filter { !bundledIDs.contains($0.id) }
    }

    func select(_ look: Look) {
        selectedLookID = look.id
        grain = look.grain
        effects = look.effects ?? .neutral
        updatePreview()
    }

    /// Receta creada (o importada) por el usuario, no uno de los incluidos.
    func isUserLook(_ look: Look) -> Bool {
        !bundledLooks.contains { $0.id == look.id } && userLooks.contains { $0.id == look.id }
    }

    /// Un Look incluido que el usuario modificó.
    func isModified(_ look: Look) -> Bool {
        bundledLooks.contains { $0.id == look.id } && userLooks.contains { $0.id == look.id }
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

    /// Tamaño (o proporción) de la imagen del visor, para ubicar el marco del recorte.
    private var sourceSize: CGSize {
        if let still = preview?.still { return CGSize(width: still.width, height: still.height) }
        if status != .running, let fallback = preview?.fallback {
            return CGSize(width: fallback.width, height: fallback.height)
        }
        return CGSize(width: 3, height: 4)  // cámara: preset .photo, 4:3 en vertical
    }

    private func updatePreview() {
        preview?.contentMode = showsWholeFrame ? .aspectFit : .aspectFill
        let split = compareSplit ?? 0
        let frame = framing.isFullFrame ? nil : framing.rect(in: sourceSize, lensFocalLength: lensFocalLength)
        if let draft {
            if let draftTexture { preview?.lut = draftTexture }
            preview?.parameters = LookParameters(intensity: intensity, grain: draft.grain, effects: draft.effects,
                                                 split: split, frame: frame)
            return
        }
        if let texture = selectedTexture {
            preview?.lut = texture
        } else if selectedLookID == nil {
            preview?.lut = nil
        }
        preview?.parameters = LookParameters(intensity: intensity, grain: grain, effects: effects, split: split,
                                             frame: frame)
    }

    // MARK: - Editor de recetas

    /// Abre el editor sobre un Look (incluido o propio): al guardar se reemplaza.
    func edit(_ look: Look) {
        loadDraftBase(of: look)
        draft = LookDraft(from: look, editingID: look.id)
    }

    /// Abre el editor sobre una copia del Look: al guardar se crea otro.
    func duplicate(_ look: Look) {
        loadDraftBase(of: look)
        draft = LookDraft(from: look, editingID: nil)
    }

    /// LUT base del Look (si es un `.cube` importado), para generar la vista previa del editor.
    private func loadDraftBase(of look: Look) {
        draftBase = look.lut.flatMap { try? LookCatalog.lut(for: Look(id: look.id, name: look.name, lut: $0)) }
    }

    /// Vuelve un Look incluido a como viene en la app.
    func restoreOriginal(_ look: Look) {
        guard isModified(look) else { return }
        userLooks.removeAll { $0.id == look.id }
        guard persistUserLooks() else { return }
        if let original = looks.first(where: { $0.id == look.id }) {
            select(original)
        }
        message = "\(look.name): original restaurado"
    }

    func newRecipe() {
        draftBase = nil
        draft = LookDraft()
    }

    func cancelEditing() {
        draft = nil
    }

    /// Guarda el borrador (reemplazando el Look que se editaba, o como uno nuevo) y lo elige.
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
        userStore?.removeLUTFile(of: look, remaining: userLooks)
        if selectedLookID == look.id, let first = looks.first(where: { $0.id != "natural" }) ?? looks.first {
            select(first)
        }
        message = "Borrada: \(look.name)"
    }

    /// Importa uno o varios LUT `.cube` del usuario como recetas (el LUT de base, sliders encima). Si
    /// alguno falla sigue con los demás, y al final avisa cuántos entraron y cuáles no.
    func importCubes(at urls: [URL]) async {
        guard let userStore, !urls.isEmpty else { return }
        var imported: [Look] = []
        var failed: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let look = try await Task.detached(priority: .userInitiated) {
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    return try userStore.importCube(text, name: name)
                }.value
                imported.append(look)
            } catch LUT3D.CubeError.has1DLUT {
                failed.append("\(url.lastPathComponent) (tiene LUT 1D o shaper)")
            } catch LUT3D.CubeError.notA3DLUT {
                failed.append("\(url.lastPathComponent) (no es un LUT 3D)")
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !imported.isEmpty {
            userLooks.append(contentsOf: imported)
            guard persistUserLooks() else { return }
            select(imported[0])
        }
        let summary = urls.count == 1 && failed.isEmpty
            ? "Importado: \(imported[0].name)"
            : "Importados \(imported.count) de \(urls.count)"
        message = failed.isEmpty ? summary : summary + " · no se pudo: " + failed.joined(separator: ", ")
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
            rebuildLooks()
            return true
        } catch {
            message = "No se pudo guardar: \(error)"
            userLooks = (try? userStore?.load()) ?? userLooks
            rebuildLooks()
            return false
        }
    }

    /// Genera el LUT del borrador: uno chico enseguida y, si los sliders se quedan quietos, el de
    /// 64³. Cada cambio cancela lo pendiente del anterior.
    private func scheduleDraftLUT() {
        draftTask?.cancel()
        let base = draftBase
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
                    LoadedTexture(texture: try renderer.makeLUTTexture(recipe.makeLUT(size: size, base: base)))
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
            photoFocalLength = Framing.lensFocalLength(ofPhoto: data)
            message = nil
            updatePreview()
        } catch {
            message = "No se pudo abrir esa foto"
        }
    }

    /// Abre una foto de Fotos para editarla sin perder el original. Si la sacó (o editó) esta app,
    /// vuelve a poner el Look, los efectos, la intensidad y el encuadre que tenía. Devuelve false si no
    /// se pudo (por ejemplo, sin acceso completo a Fotos): entonces conviene abrirla como copia.
    func openPhotoForEditing(localIdentifier: String) async -> Bool {
        do {
            let editable = try await PhotoLibrary.openForEditing(localIdentifier: localIdentifier,
                                                                 format: Self.adjustmentFormat)
            await usePhoto(editable.original)
            guard photo != nil else { return false }
            editingPhoto = editable
            if let data = editable.adjustment, let adjustment = PhotoAdjustment(data: data) {
                restore(adjustment)
            }
            return true
        } catch {
            return false
        }
    }

    /// Vuelve a poner lo aplicado a una foto. Busca el mismo Look (misma receta) o, si cambió, el de
    /// mismo id; los efectos, el grano y el encuadre se toman de la foto.
    private func restore(_ adjustment: PhotoAdjustment) {
        let stored = adjustment.look
        if let look = looks.first(where: { $0.lutKey == stored.lutKey }) ?? looks.first(where: { $0.id == stored.id }) {
            select(look)
            if look.lutKey != stored.lutKey {
                message = "La receta de \(look.name) cambió desde que sacaste la foto"
            }
        } else {
            message = "El Look de esta foto ya no está en la lista"
        }
        grain = stored.grain
        effects = stored.effects ?? .neutral
        intensity = adjustment.intensity
        photoFocalLength = adjustment.lensFocalLength
        framing = adjustment.framing
        updatePreview()
    }

    /// Vuelve a la cámara (o al patrón de prueba).
    func closePhoto() {
        photo = nil
        editingPhoto = nil
        preview?.still = nil
        updatePreview()
    }

    static let adjustmentFormat = PhotoLibrary.AdjustmentFormat(identifier: PhotoAdjustment.formatIdentifier,
                                                                version: PhotoAdjustment.formatVersion)

    /// Lo aplicado ahora (Look, efectos, grano, intensidad, encuadre), para guardar con la foto.
    private func currentAdjustment() throws -> Data {
        let base = selectedLook ?? Look(id: "natural", name: "Natural", recipe: .neutral)
        let look = Look(id: base.id, name: base.name, lut: base.lut, recipe: base.recipe, grain: grain,
                        effects: effects.isNeutral ? nil : effects)
        return try PhotoAdjustment(look: look, intensity: intensity, framing: framing,
                                   lensFocalLength: lensFocalLength).encoded()
    }

    /// Foto de la fototeca: guarda los cambios en la misma foto (el original queda, y se puede volver a
    /// editar o revertir en Fotos) o, si no se pudo abrir para editar, una copia con el Look.
    private func savePhotoWithLook(_ data: Data) async {
        guard !isCapturing else { return }
        guard let job = bakeJob(outputType: .jpeg) else {
            message = "Esperá a que cargue el Look"
            return
        }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try job.render(data)
            }.value
            if let editingPhoto {
                try await PhotoLibrary.saveEdit(of: editingPhoto, rendered: rendered, adjustment: currentAdjustment(),
                                                format: Self.adjustmentFormat)
                // La foto ahora tiene esta edición: reabrirla para que el próximo guardado parta de acá.
                _ = await openPhotoForEditing(localIdentifier: editingPhoto.localIdentifier)
                message = "Cambios guardados (en Fotos se pueden revertir)"
            } else {
                try await PhotoLibrary.save(processed: rendered, raw: nil)
                message = "Copia guardada con \(selectedLook?.name ?? "el Look")"
            }
        } catch {
            message = "No se pudo guardar: \(error)"
        }
    }

    /// Look, efectos, grano y recorte actuales, para aplicarlos a una foto fuera del main actor.
    private func bakeJob(requiringLUT: Bool = true, outputType: UTType? = nil) -> BakeJob? {
        guard let renderer = preview?.looks else { return nil }
        let lut = selectedTexture
        if requiringLUT, lut == nil { return nil }
        return BakeJob(renderer: renderer, lut: lut,
                       parameters: LookParameters(intensity: intensity, grain: grain, effects: effects,
                                                  seed: .random(in: 0...UInt32.max)),
                       framing: framing, lensFocalLength: lensFocalLength,
                       outputType: outputType ?? (settings.photoFormat.processed == .heic ? .heic : .jpeg))
    }

    func capture() async {
        if let photo {
            await savePhotoWithLook(photo)
            return
        }
        guard status == .running, !isCapturing, preview != nil else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let photo = try await camera.capturePhoto(settings: settings)
            // Sin LUT cargado todavía, igual se recorta al marco. La versión con el Look va en JPEG (es
            // lo que acepta una edición de Fotos); el original queda en el formato elegido.
            if let processed = photo.processed, let job = bakeJob(requiringLUT: false, outputType: .jpeg) {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try job.render(processed)
                }.value
                try await PhotoLibrary.saveEditable(original: processed, rendered: rendered,
                                                    adjustment: currentAdjustment(), format: Self.adjustmentFormat,
                                                    raw: photo.raw)
            } else {
                try await PhotoLibrary.save(processed: photo.processed, raw: photo.raw)
            }
            message = "Guardada (\(settings.photoFormat.rawValue))"
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
    let lut: MTLTexture?
    let parameters: LookParameters
    let framing: Framing
    let lensFocalLength: Double
    let outputType: UTType

    func render(_ data: Data) throws -> Data {
        try renderer.renderPhoto(data, lut: lut, parameters: parameters, framing: framing,
                                 lensFocalLength: lensFocalLength, outputType: outputType)
    }
}

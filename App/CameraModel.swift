import CaptureCore
import CoreGraphics
import Foundation
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
    /// Miniaturas, favoritos y color / blanco y negro, para el selector.
    let gallery = LookGallery()
    /// Los Looks en el orden del selector: Natural, los favoritos y el resto.
    var arrangedLooks: [Look] {
        LookOrder.arranged(looks, favorites: gallery.favorites)
    }
    private var bundledLooks: [Look] = []
    private(set) var userLooks: [Look] = []
    private(set) var capabilities: CameraCapabilities?
    private(set) var isCapturing = false
    /// Aviso que se muestra unos segundos y se va solo.
    private(set) var message: String? {
        didSet {
            messageTask?.cancel()
            guard message != nil else { return }
            messageTask = Task { [weak self] in
                try? await Task.sleep(for: Self.messageDuration)
                guard !Task.isCancelled else { return }
                self?.message = nil
            }
        }
    }
    private var messageTask: Task<Void, Never>?
    private static let messageDuration = Duration.seconds(4)
    /// Foto de la fototeca para probar Looks: mientras está, el visor la muestra en vez de la cámara.
    /// El disparador guarda los cambios en la misma foto (`editingPhoto`) o, si no se pudo abrir para
    /// editar, una copia con el Look.
    private(set) var photo: Data?
    /// La foto de Fotos que se está editando, con su original y los ajustes guardados.
    private(set) var editingPhoto: PhotoLibrary.EditablePhoto?

    var selectedLookID: String? {
        didSet {
            // Al volver a abrir la app, arranca con el último Look elegido.
            if let selectedLookID { UserDefaults.standard.set(selectedLookID, forKey: Self.lastLookKey) }
            loadSelectedLUT()
            updatePreview()
        }
    }
    private static let lastLookKey = "ultimoLook"
    var intensity: Float = 1 { didSet { updatePreview() } }
    var grain: Float = 0 { didSet { updatePreview() } }
    /// Efectos del Look elegido.
    private(set) var effects = LookEffects.neutral
    /// Recorte por focal y formato: marco en el visor, foto recortada al guardar.
    var framing = Framing() { didSet { updatePreview() } }
    /// Focal equivalente del lente de la foto de la fototeca (de su EXIF).
    private var photoFocalLength: Double?
    /// Cálculo del recorte de persona de la foto abierta.
    private var stillMatteTask: Task<Void, Never>?
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
    var settings = CaptureSettings() {
        didSet {
            guard settings != oldValue else { return }
            applySettings()
            // P/A y el f-número cambian el bokeh del visor; P ↔ A, además, la cámara.
            if settings.program != oldValue.program { updatePreview() }
            if Self.usesDepth(settings.program) != Self.usesDepth(oldValue.program) {
                switchCamera(depth: Self.usesDepth(settings.program))
            }
        }
    }
    /// Punto tocado para enfocar, 0…1 sobre el visor; nil = foco automático.
    private(set) var focusPoint: CGPoint?
    /// Se está arrastrando el dedo para cambiar el brillo.
    private(set) var isAdjustingBrightness = false
    /// El cuadrado del foco se ve: unos segundos después de tocar o de cambiar el brillo. El foco
    /// sigue fijo aunque no se vea.
    private(set) var isFocusSquareVisible = false
    private var focusSquareTask: Task<Void, Never>?
    private static let focusSquareDuration = Duration.seconds(2.5)
    private var brightnessDragStart: Float = 0
    /// Ya se explicó cómo volver al foco automático (una vez por sesión).
    private var didExplainFocusLock = false
    /// Puntos que hay que arrastrar el dedo (y que se mueve el sol) por cada paso de EV.
    static let pointsPerEV: CGFloat = 25
    /// Modo A: el f-número simulado desenfoca el fondo detrás de las personas al guardar la foto.
    var bokeh: Bokeh? {
        if case .aperturePriority(let fNumber) = settings.program {
            Bokeh(fNumber: fNumber, focus: bokehFocus, capturedFocus: opticalFocus)
        } else {
            nil
        }
    }
    /// Lo que queda nítido en el bokeh: el punto tocado, en coordenadas 0…1 de la imagen entera y
    /// derecha. nil = automático (la persona o el centro).
    private(set) var bokehFocus: Bokeh.FocusPoint?
    /// Dónde enfocó la lente (disparidad, 1/m) al sacar la foto que se guarda o se edita, si se sabe.
    private var opticalFocus: Float?
    /// Mapa de profundidad y recorte de persona de la foto abierta, para el bokeh del visor.
    private var stillDepth: DepthMap?
    private var stillPersonMatte: PersonMatte?
    /// Ya se buscaron la profundidad y la persona de la foto abierta (estén o no).
    private var isStillAnalyzed = false

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
            camera.setDepthHandler { [liveDepth = preview.liveDepth] depth in liveDepth.process(depth) }
            capabilities = try await camera.configure(depth: Self.usesDepth(settings.program))
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
        let lastID = UserDefaults.standard.string(forKey: Self.lastLookKey)
        if let look = looks.first(where: { $0.id == lastID }) ?? looks.first(where: { $0.id != "natural" }) ?? looks.first {
            select(look)
        }
    }

    /// Los incluidos (con los cambios del usuario encima) y después los propios.
    private func rebuildLooks() {
        let bundledIDs = Set(bundledLooks.map(\.id))
        looks = bundledLooks.map { look in userLooks.first { $0.id == look.id } ?? look }
            + userLooks.filter { !bundledIDs.contains($0.id) }
        if let renderer = preview?.looks {
            gallery.update(looks: looks, renderer: renderer)
        }
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
        preview?.bokeh = bokeh
        preview?.liveDepth.bokeh = bokeh
        preview?.liveDepth.isEnabled = bokeh != nil && photo == nil && status == .running
            && capabilities?.hasDepth == true
        preview?.lensFocalLength = lensFocalLength
        preview?.focalLength = framing.focalLength ?? lensFocalLength
        preview?.depthFocus = bokeh.flatMap { bokeh in stillDepth?.focus(for: bokeh, matte: stillPersonMatte) }
        // El recorte en vivo solo corre en modo A con la cámara (con una foto abierta se usa el suyo).
        preview?.liveMatte.isEnabled = bokeh != nil && photo == nil && status == .running
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

    /// Modo A: cámara con profundidad (para el bokeh). Modo P: la principal sola, con ProRAW.
    private static func usesDepth(_ program: ExposureProgram) -> Bool {
        if case .aperturePriority = program { true } else { false }
    }

    /// Cambia de cámara al pasar de P a A (o al revés) y vuelve a aplicar la exposición.
    private func switchCamera(depth: Bool) {
        guard status == .running else { return }
        focusPoint = nil
        bokehFocus = nil
        Task {
            do {
                let updated = try await camera.setDepthMode(depth)
                capabilities = updated
                updatePreview()
                if !updated.isRAWSupported, settings.photoFormat.includesRAW {
                    settings.photoFormat = settings.photoFormat.withoutRAW
                }
                applySettings()
            } catch {
                message = "No se pudo cambiar de cámara: \(error)"
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

    // MARK: - Foco por toque

    /// Se puede tocar el visor para enfocar: cámara en vivo, sin foto abierta, editor ni comparación.
    var canTapToFocus: Bool {
        status == .running && photo == nil && draft == nil && compareSplit == nil
    }

    /// Editando una foto en modo A, tocarla elige qué queda nítido en el bokeh.
    var canTapToChooseBokehFocus: Bool {
        photo != nil && bokeh != nil && draft == nil && compareSplit == nil && stillDepth != nil
    }

    /// Se muestra el cuadrado del foco.
    var showsFocusSquare: Bool {
        canTapToFocus || canTapToChooseBokehFocus
    }

    /// El brillo (compensación EV) solo se puede tocar con la exposición automática.
    var canAdjustBrightness: Bool {
        settings.iso == nil && settings.shutterSeconds == nil
    }

    /// Rango de la compensación EV, el mismo que en los controles manuales.
    var exposureBiasRange: ClosedRange<Float> {
        max(-3, limits.biasRange.lowerBound)...min(3, limits.biasRange.upperBound)
    }

    /// Enfoca y mide la luz donde se tocó. `point` va en puntos de la vista de tamaño `viewSize`.
    /// En modo A, ese punto es también lo que queda nítido en el bokeh. Con una foto abierta, solo eso.
    func focus(atViewPoint point: CGPoint, viewSize: CGSize) {
        if photo != nil, draft == nil, compareSplit == nil, !canTapToChooseBokehFocus {
            explainWhyBokehFocusIsUnavailable()
            return
        }
        guard canTapToFocus || canTapToChooseBokehFocus, viewSize.width > 0, viewSize.height > 0 else { return }
        let normalized = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        guard let framePoint = preview?.imagePoint(forViewPoint: normalized, viewSize: viewSize),
              (0...1).contains(framePoint.x), (0...1).contains(framePoint.y)
        else { return }
        // Tocar el cuadrado (mientras se ve) vuelve al foco automático.
        if isFocusSquareVisible, let current = focusPoint,
           hypot((current.x - normalized.x) * viewSize.width, (current.y - normalized.y) * viewSize.height) < 44 {
            clearFocus()
            return
        }
        focusPoint = normalized
        revealFocusSquare()
        bokehFocus = Bokeh.FocusPoint(x: Float(framePoint.x), y: Float(framePoint.y))
        if !didExplainFocusLock {
            didExplainFocusLock = true
            message = "Foco fijo ahí. Tocá el cuadrado para volver al automático"
        }

        updatePreview()
        guard photo == nil else {
            warnIfOutsideTheOpticalFocus()
            return
        }
        let devicePoint = FocusGeometry.devicePoint(fromFrame: framePoint)
        Task {
            do {
                try await camera.focus(at: devicePoint)
            } catch {
                message = "No se pudo enfocar: \(error)"
            }
        }
    }

    /// Editando: si el plano elegido estaba lejos de donde enfocó la lente, ya salió borroso.
    private func warnIfOutsideTheOpticalFocus() {
        guard let opticalFocus, let chosen = preview?.depthFocus,
              abs(chosen.disparity - opticalFocus) * chosen.scale > Bokeh.opticalFocusTolerance
        else { return }
        message = "Esa zona no estaba en foco cuando sacaste la foto: no va a quedar nítida"
    }

    /// Por qué tocar la foto abierta no elige qué queda nítido.
    private func explainWhyBokehFocusIsUnavailable() {
        if bokeh == nil {
            message = "Pasá a modo A para elegir qué queda nítido"
        } else if !isStillAnalyzed {
            message = "Un momento: leyendo la profundidad de la foto"
        } else {
            message = "Esta foto no tiene profundidad: el desenfoque sigue a la persona"
        }
    }

    /// Con el foco tocado y exposición automática, arrastrar el dedo por el visor cambia el brillo.
    var canDragBrightness: Bool {
        canTapToFocus && focusPoint != nil && canAdjustBrightness
    }

    /// Arrastre vertical sobre el visor: hacia arriba aclara, hacia abajo oscurece (compensación EV,
    /// en pasos de 0,1). `translation` en puntos desde que empezó; nil al soltar.
    func dragBrightness(by translation: CGFloat?) {
        guard let translation else {
            if isAdjustingBrightness {
                isAdjustingBrightness = false
                revealFocusSquare()
            }
            return
        }
        guard canDragBrightness else { return }
        if !isAdjustingBrightness {
            isAdjustingBrightness = true
            brightnessDragStart = settings.exposureBias
            isFocusSquareVisible = true
            focusSquareTask?.cancel()
        }
        let range = exposureBiasRange
        let bias = min(max(brightnessDragStart - Float(translation / Self.pointsPerEV), range.lowerBound), range.upperBound)
        settings.exposureBias = (bias * 10).rounded() / 10
    }

    /// Muestra el cuadrado del foco y lo esconde unos segundos después.
    private func revealFocusSquare() {
        isFocusSquareVisible = true
        focusSquareTask?.cancel()
        focusSquareTask = Task { [weak self] in
            try? await Task.sleep(for: Self.focusSquareDuration)
            guard !Task.isCancelled, let self, !self.isAdjustingBrightness else { return }
            self.isFocusSquareVisible = false
        }
    }

    /// Vuelve al foco automático: la cámara enfoca sola y el bokeh enfoca la persona o el centro.
    func clearFocus() {
        guard focusPoint != nil || bokehFocus != nil else { return }
        focusPoint = nil
        bokehFocus = nil
        focusSquareTask?.cancel()
        isFocusSquareVisible = false
        updatePreview()
        if photo == nil {
            Task { try? await camera.resetFocus() }
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
            preview?.stillMatte = nil
            preview?.stillDepth = nil
            stillDepth = nil
            stillPersonMatte = nil
            isStillAnalyzed = false
            bokehFocus = nil
            opticalFocus = nil
            focusPoint = nil
            photo = data
            photoFocalLength = Framing.lensFocalLength(ofPhoto: data)
            message = nil
            updatePreview()
            loadStillMatte(for: data)
        } catch {
            message = "No se pudo abrir esa foto"
        }
    }

    /// Recorte de la persona de la foto abierta, para ver el bokeh en el visor (con la calidad de la
    /// foto final: se calcula una sola vez).
    /// También su mapa de profundidad, si lo tiene: con eso el visor muestra el bokeh por distancia.
    private func loadStillMatte(for data: Data) {
        guard let renderer = preview?.looks else { return }
        stillMatteTask?.cancel()
        stillMatteTask = Task {
            let loaded = await Task.detached(priority: .utility) {
                let matte = PersonMatte.best(inPhoto: data)
                let depth = DepthMap.load(fromPhoto: data)
                return StillAnalysis(matte: matte, matteTexture: matte.flatMap { try? renderer.makeTexture(matte: $0) },
                                     depth: depth, depthTexture: depth.flatMap { try? renderer.makeTexture(depth: $0) })
            }.value
            guard !Task.isCancelled, photo == data else { return }
            stillPersonMatte = loaded.matte
            stillDepth = loaded.depth
            isStillAnalyzed = true
            preview?.stillMatte = loaded.matteTexture
            preview?.stillDepth = loaded.depthTexture
            updatePreview()
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
    /// mismo id; los efectos, el grano, el encuadre y el bokeh se toman de la foto.
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
        // El modo de arriba (P o A y su f-número) muestra el bokeh que tiene la foto.
        settings.program = adjustment.bokeh.map { .aperturePriority(fNumber: $0.fNumber) } ?? .program
        bokehFocus = adjustment.bokeh?.focus
        opticalFocus = adjustment.bokeh?.capturedFocus
        updatePreview()
    }

    /// Vuelve a la cámara (o al patrón de prueba).
    func closePhoto() {
        photo = nil
        editingPhoto = nil
        stillMatteTask?.cancel()
        preview?.still = nil
        preview?.stillMatte = nil
        preview?.stillDepth = nil
        stillDepth = nil
        stillPersonMatte = nil
        bokehFocus = nil
        opticalFocus = nil
        focusPoint = nil
        updatePreview()
    }

    static let adjustmentFormat = PhotoLibrary.AdjustmentFormat(identifier: PhotoAdjustment.formatIdentifier,
                                                                version: PhotoAdjustment.formatVersion)

    /// Lo aplicado ahora (Look, efectos, grano, intensidad, encuadre, bokeh), para guardar con la foto.
    private func currentAdjustment() throws -> Data {
        let base = selectedLook ?? Look(id: "natural", name: "Natural", recipe: .neutral)
        let look = Look(id: base.id, name: base.name, lut: base.lut, recipe: base.recipe, grain: grain,
                        effects: effects.isNeutral ? nil : effects)
        return try PhotoAdjustment(look: look, intensity: intensity, framing: framing,
                                   lensFocalLength: lensFocalLength, bokeh: bokeh).encoded()
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

    /// Look, efectos, grano, recorte y bokeh actuales, para aplicarlos a una foto fuera del main actor.
    private func bakeJob(requiringLUT: Bool = true, outputType: UTType? = nil) -> BakeJob? {
        guard let renderer = preview?.looks else { return nil }
        let lut = selectedTexture
        if requiringLUT, lut == nil { return nil }
        return BakeJob(renderer: renderer, lut: lut,
                       parameters: LookParameters(intensity: intensity, grain: grain, effects: effects,
                                                  seed: .random(in: 0...UInt32.max)),
                       framing: framing, lensFocalLength: lensFocalLength, bokeh: bokeh,
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
            // Con un punto tocado, la lente enfocó ahí: se guarda su distancia para avisar al editar.
            if let tapped = bokeh, tapped.focus != nil, let processed = photo.processed {
                opticalFocus = await Task.detached(priority: .userInitiated) {
                    DepthMap.load(fromPhoto: processed)?.focus(for: tapped, matte: nil).disparity
                }.value
            }
            defer { opticalFocus = nil }
            // Sin LUT cargado todavía, igual se recorta al marco (y en modo A, se desenfoca el fondo). La
            // versión con el Look va en JPEG (es lo que acepta una edición de Fotos); el original queda en
            // el formato elegido.
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

/// Lo que se calcula de una foto abierta para su bokeh en el visor. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct StillAnalysis: @unchecked Sendable {
    let matte: PersonMatte?
    let matteTexture: MTLTexture?
    let depth: DepthMap?
    let depthTexture: MTLTexture?
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
    let bokeh: Bokeh?
    let outputType: UTType

    func render(_ data: Data) throws -> Data {
        try renderer.renderPhoto(data, lut: lut, parameters: parameters, framing: framing,
                                 lensFocalLength: lensFocalLength, bokeh: bokeh, outputType: outputType)
    }
}

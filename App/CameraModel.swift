import CaptureCore
import Looks
import Metal
import Observation

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
    private(set) var looks: [Look] = []
    private(set) var capabilities: CameraCapabilities?
    private(set) var isCapturing = false
    private(set) var message: String?

    var selectedLookID: String? { didSet { loadSelectedLUT(); updatePreview() } }
    var intensity: Float = 1 { didSet { updatePreview() } }
    var grain: Float = 0 { didSet { updatePreview() } }
    var settings = CaptureSettings() { didSet { if settings != oldValue { applySettings() } } }

    let preview: PreviewRenderer?
    private let camera = CameraController()
    /// Texturas de LUT ya cargadas, por id de Look. Se cargan al elegir cada Look.
    private var lutTextures: [String: MTLTexture] = [:]
    private var loadingLUTs: Set<String> = []

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
            looks = try LookCatalog.bundled()
            if let first = looks.first(where: { $0.id != "identidad" }) ?? looks.first {
                selectedLookID = first.id
                grain = first.grain
            }
        } catch {
            message = "No se pudieron cargar los Looks: \(error)"
        }
    }

    func select(_ look: Look) {
        selectedLookID = look.id
        grain = look.grain
    }

    /// Genera (receta) o lee (.lut) el LUT del Look elegido fuera del main actor y cachea la
    /// textura. Mientras tanto el preview sigue con el LUT anterior.
    private func loadSelectedLUT() {
        guard let look = selectedLook, let renderer = preview?.looks,
              lutTextures[look.id] == nil, !loadingLUTs.contains(look.id)
        else { return }
        loadingLUTs.insert(look.id)
        Task {
            defer { loadingLUTs.remove(look.id) }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    LoadedLUT(texture: try renderer.makeLUTTexture(LookCatalog.lut(for: look)))
                }.value
                lutTextures[look.id] = loaded.texture
                updatePreview()
            } catch {
                message = "No se pudo cargar \(look.name): \(error)"
                if selectedLookID == look.id { preview?.lut = nil }
            }
        }
    }

    private func updatePreview() {
        if let texture = selectedLookID.flatMap({ lutTextures[$0] }) {
            preview?.lut = texture
        } else if selectedLookID == nil {
            preview?.lut = nil
        }
        preview?.parameters = LookParameters(intensity: intensity, grain: grain)
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

    func capture() async {
        guard status == .running, !isCapturing, let preview else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            var photo = try await camera.capturePhoto(settings: settings)
            if let processed = photo.processed, let lut = selectedLookID.flatMap({ lutTextures[$0] }) {
                let job = BakeJob(renderer: preview.looks, lut: lut,
                                  parameters: LookParameters(intensity: intensity, grain: grain, seed: .random(in: 0...UInt32.max)))
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

/// Textura de LUT recién subida desde una tarea de fondo. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct LoadedLUT: @unchecked Sendable {
    let texture: MTLTexture
}

/// Lo necesario para hornear el Look fuera del main actor. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct BakeJob: @unchecked Sendable {
    let renderer: LookRenderer
    let lut: MTLTexture
    let parameters: LookParameters
}

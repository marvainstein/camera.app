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

    var selectedLookID: String? { didSet { updatePreview() } }
    var intensity: Float = 1 { didSet { updatePreview() } }
    var grain: Float = 0 { didSet { updatePreview() } }
    var settings = CaptureSettings() { didSet { if settings != oldValue { applySettings() } } }

    let preview: PreviewRenderer?
    private let camera = CameraController()
    private var lutTextures: [String: MTLTexture] = [:]

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
        loadLooks(into: preview)

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

    private func loadLooks(into preview: PreviewRenderer) {
        do {
            looks = try LookCatalog.bundled()
            for look in looks {
                lutTextures[look.id] = try preview.looks.makeLUTTexture(LookCatalog.lut(for: look))
            }
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

    private func updatePreview() {
        preview?.lut = selectedLookID.flatMap { lutTextures[$0] }
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

/// Lo necesario para hornear el Look fuera del main actor. `MTLTexture` es inmutable una vez
/// subida y Metal es seguro entre hilos.
private struct BakeJob: @unchecked Sendable {
    let renderer: LookRenderer
    let lut: MTLTexture
    let parameters: LookParameters
}

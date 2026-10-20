import CoreVideo
import Looks
import MetalKit
import SwiftUI

/// Dibuja el último frame de la cámara (o el patrón de prueba) con el Look aplicado.
@MainActor
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let looks: LookRenderer
    var lut: MTLTexture?
    var parameters = LookParameters()
    /// Fuente cuando no hay cámara (simulador).
    var fallback: MTLTexture?
    /// Foto elegida de la fototeca: mientras está, se muestra en vez de la cámara.
    var still: MTLTexture?
    /// Cámara en vivo: llenar la pantalla; foto o editor: la imagen entera.
    var contentMode = LookContentMode.aspectFill

    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private nonisolated(unsafe) var pendingFrame: CVPixelBuffer?
    private var frameIndex: UInt32 = 0

    init(looks: LookRenderer) throws {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, looks.device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw LookRendererError.resourceCreationFailed("texture cache")
        }
        self.looks = looks
        self.textureCache = cache
    }

    /// Se llama desde la cola de video de la cámara.
    nonisolated func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.withLock { pendingFrame = pixelBuffer }
    }

    private func latestFrame() -> CVPixelBuffer? {
        lock.withLock { pendingFrame }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        var cameraTexture: CVMetalTexture?
        var source = still ?? fallback
        if still == nil, let frame = latestFrame() {
            let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
            if CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, frame, nil, .bgra8Unorm,
                                                         width, height, 0, &cameraTexture) == kCVReturnSuccess,
               let cameraTexture {
                source = CVMetalTextureGetTexture(cameraTexture)
            }
        }
        guard let source, let drawable = view.currentDrawable,
              let commandBuffer = looks.commandQueue.makeCommandBuffer()
        else { return }

        frameIndex &+= 1
        var parameters = parameters
        parameters.seed = frameIndex
        do {
            try looks.encode(commandBuffer: commandBuffer, source: source, lut: lut,
                             destination: drawable.texture, parameters: parameters, contentMode: contentMode)
        } catch {
            return
        }
        commandBuffer.present(drawable)
        // Mantener viva la textura de la cámara hasta que la GPU termine.
        nonisolated(unsafe) let retained = cameraTexture
        commandBuffer.addCompletedHandler { _ in _ = retained }
        commandBuffer.commit()
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.looks.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

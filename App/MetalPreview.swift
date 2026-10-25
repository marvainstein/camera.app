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
    /// Modo A: desenfoque del fondo detrás de las personas, igual que en la foto final.
    var bokeh: Bokeh?
    /// Recorte de la persona de la foto de la fototeca (derecho, como `still`).
    var stillMatte: MTLTexture?
    /// Mapa de profundidad de la foto de la fototeca (derecho), si lo tiene, y dónde enfocar.
    var stillDepth: MTLTexture?
    var depthFocus: DepthMap.Focus?
    /// Recorte de la persona y profundidad en vivo, para la cámara.
    let liveMatte: LiveMatte
    let liveDepth: LiveDepth
    /// Focal simulada (la del encuadre) y la del lente, para el desenfoque por profundidad.
    var focalLength: Double = 24
    var lensFocalLength: Double = 24
    private let bokehScratch = BokehScratch()
    /// Imagen con el bokeh, del tamaño de la fuente; se reutiliza cuadro a cuadro.
    private var bokehTarget: MTLTexture?

    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private nonisolated(unsafe) var pendingFrame: CVPixelBuffer?
    private var frameIndex: UInt32 = 0
    /// Tamaño (en píxeles) de la última imagen dibujada, para pasar toques a coordenadas de la imagen.
    private(set) var sourceSize: (Int, Int)?

    init(looks: LookRenderer) throws {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, looks.device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw LookRendererError.resourceCreationFailed("texture cache")
        }
        self.looks = looks
        self.textureCache = cache
        let liveMatte = LiveMatte(renderer: looks)
        self.liveMatte = liveMatte
        self.liveDepth = LiveDepth(renderer: looks, liveMatte: liveMatte)
    }

    /// Se llama desde la cola de video de la cámara.
    nonisolated func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.withLock { pendingFrame = pixelBuffer }
        liveMatte.process(pixelBuffer)
    }

    private func latestFrame() -> CVPixelBuffer? {
        lock.withLock { pendingFrame }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// La fuente con el bokeh (versión liviana), o nil si no corresponde: modo P, sin persona o con
    /// un desenfoque que no se notaría.
    private func encodeBokeh(commandBuffer: MTLCommandBuffer, source: MTLTexture) throws -> MTLTexture? {
        guard let bokeh, bokeh.isVisible(shortSide: min(source.width, source.height)) else { return nil }
        if bokehTarget?.width != source.width || bokehTarget?.height != source.height {
            bokehTarget = try looks.makeRenderTarget(width: source.width, height: source.height)
        }
        guard let target = bokehTarget else { return nil }
        // Con profundidad (la de la foto abierta o la de la cámara en vivo): desenfoque por distancia,
        // como el que se va a guardar.
        let depth: (texture: MTLTexture, focus: DepthMap.Focus, matte: MTLTexture?)? =
            if still != nil {
                stillDepth.flatMap { texture in depthFocus.map { (texture, $0, stillMatte) } }
            } else {
                liveDepth.frame.map { ($0.texture, $0.focus, liveMatte.texture) }
            }
        if let depth {
            try looks.encodeDepthBokeh(commandBuffer: commandBuffer, source: source, depth: depth.texture,
                                       matte: depth.matte, focus: depth.focus, destination: target, bokeh: bokeh,
                                       focalLength: focalLength, lensFocalLength: lensFocalLength,
                                       quality: .preview, scratch: bokehScratch)
            return target
        }
        guard let matte = still != nil ? stillMatte : liveMatte.texture else { return nil }
        // La foto y los cuadros del visor ya están derechos, igual que sus recortes.
        try looks.encodeBokeh(commandBuffer: commandBuffer, source: source, matte: matte, destination: target,
                              bokeh: bokeh, orientation: 1, quality: .preview, scratch: bokehScratch)
        return target
    }

    /// Un punto del visor (0…1 sobre la vista de tamaño `viewSize`) en coordenadas 0…1 de la imagen
    /// que se muestra, teniendo en cuenta lo que recorta `contentMode`. nil si todavía no hay imagen.
    func imagePoint(forViewPoint point: CGPoint, viewSize: CGSize) -> CGPoint? {
        guard let sourceSize, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let t = LookRenderer.uvTransform(source: sourceSize,
                                         destination: (Int(viewSize.width.rounded()), Int(viewSize.height.rounded())),
                                         contentMode: contentMode)
        return CGPoint(x: point.x * CGFloat(t.x) + CGFloat(t.z), y: point.y * CGFloat(t.y) + CGFloat(t.w))
    }

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
        sourceSize = (source.width, source.height)
        var parameters = parameters
        parameters.seed = frameIndex
        do {
            // El bokeh va antes del Look, como en la foto; al comparar, el "antes" es la fuente sin nada.
            let shown = try encodeBokeh(commandBuffer: commandBuffer, source: source) ?? source
            try looks.encode(commandBuffer: commandBuffer, source: shown, lut: lut,
                             destination: drawable.texture, parameters: parameters, contentMode: contentMode,
                             original: source)
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

/// Gestos sobre el visor. Los recibe la propia vista de Metal: una capa de SwiftUI encima no siempre
/// se entera de los toques que caen sobre una vista de UIKit.
struct PreviewGestures {
    /// Toque: punto en la vista y tamaño de la vista.
    var onTap: (CGPoint, CGSize) -> Void
    /// Arrastre vertical: puntos desde que empezó (positivo = hacia abajo); nil al soltar.
    var onVerticalDrag: (CGFloat?) -> Void
    /// Si ahora se puede arrastrar (si no, el arrastre no empieza).
    var canDrag: () -> Bool
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer
    var gestures: PreviewGestures?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.looks.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        view.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        context.coordinator.gestures = gestures
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.gestures = gestures
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var gestures: PreviewGestures?

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            gestures?.onTap(recognizer.location(in: view), view.bounds.size)
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed: gestures?.onVerticalDrag(recognizer.translation(in: view).y)
            default: gestures?.onVerticalDrag(nil)
            }
        }

        /// El arrastre solo empieza si es más vertical que horizontal y se puede ajustar el brillo.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x) && (gestures?.canDrag() ?? false)
        }
    }
}

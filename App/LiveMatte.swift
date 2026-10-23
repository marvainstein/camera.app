import CoreVideo
import Foundation
import Looks
import Metal
import os

/// Recorte de la persona en vivo, para mostrar el bokeh en el visor. Corre Vision sobre algunos
/// cuadros de la cámara (no todos), en una cola aparte, y deja lista la textura del último recorte.
final class LiveMatte: @unchecked Sendable {
    private struct State {
        var isEnabled = false
        var isBusy = false
        var lastStart: ContinuousClock.Instant?
        var previous: PersonMatte?
        /// Cuadros seguidos sin persona.
        var misses = 0
        var texture: MTLTexture?
    }

    private let renderer: LookRenderer
    private let queue = DispatchQueue(label: "camera.live-matte", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Cada cuánto, como mucho, se recorta un cuadro (unas 15 veces por segundo).
    private static let interval = Duration.milliseconds(66)
    /// Cuánto pesa el recorte nuevo contra el anterior: suaviza el borde para que no titile.
    private static let blendWeight: Float = 0.6
    /// Cuadros seguidos sin persona antes de dejar de mostrar el bokeh (un cuadro fallido no apaga
    /// el efecto).
    private static let maxMisses = 3

    init(renderer: LookRenderer) {
        self.renderer = renderer
    }

    /// Solo trabaja en modo A con la cámara en vivo. Al apagarse olvida el último recorte.
    var isEnabled: Bool {
        get { state.withLockUnchecked { $0.isEnabled } }
        set {
            state.withLockUnchecked { state in
                state.isEnabled = newValue
                if !newValue {
                    state.previous = nil
                    state.texture = nil
                    state.misses = 0
                }
            }
        }
    }

    /// Textura `.r8Unorm` del último recorte, derecha como los cuadros del visor. nil = sin persona.
    var texture: MTLTexture? {
        state.withLockUnchecked { $0.texture }
    }

    /// Se llama desde la cola de video con cada cuadro (ya derecho). Si no toca recortar, no hace nada.
    func process(_ frame: CVPixelBuffer) {
        let shouldRun = state.withLockUnchecked { state -> Bool in
            guard state.isEnabled, !state.isBusy else { return false }
            let now = ContinuousClock.now
            if let last = state.lastStart, now - last < Self.interval { return false }
            state.isBusy = true
            state.lastStart = now
            return true
        }
        guard shouldRun else { return }
        nonisolated(unsafe) let frame = frame
        queue.async { [self] in
            let previous = state.withLockUnchecked { $0.previous }
            let matte = PersonMatte.detect(inFrame: frame)?.blended(withPrevious: previous, weight: Self.blendWeight)
            let texture = matte.flatMap { try? renderer.makeTexture(matte: $0) }
            state.withLockUnchecked { state in
                state.isBusy = false
                guard state.isEnabled else { return }
                if let matte, let texture {
                    state.previous = matte
                    state.texture = texture
                    state.misses = 0
                } else {
                    state.misses += 1
                    if state.misses >= Self.maxMisses {
                        state.previous = nil
                        state.texture = nil
                    }
                }
            }
        }
    }
}

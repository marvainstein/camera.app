import AVFoundation
import Foundation
import Looks
import Metal
import os

/// Profundidad en vivo, para que el visor muestre el mismo bokeh por distancia que va a tener la foto.
/// Toma algunos mapas de la cámara (no todos), en una cola aparte, y deja lista la textura del último
/// con su plano de foco.
final class LiveDepth: @unchecked Sendable {
    /// El último mapa listo para el visor.
    struct Frame: @unchecked Sendable {
        let texture: MTLTexture
        let focus: DepthMap.Focus
    }

    private struct State {
        var isEnabled = false
        var isBusy = false
        var lastStart: ContinuousClock.Instant?
        var bokeh: Bokeh?
        var frame: Frame?
    }

    private let renderer: LookRenderer
    private let liveMatte: LiveMatte
    private let queue = DispatchQueue(label: "camera.live-depth", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Cada cuánto, como mucho, se toma un mapa (unas 15 veces por segundo).
    private static let interval = Duration.milliseconds(66)

    init(renderer: LookRenderer, liveMatte: LiveMatte) {
        self.renderer = renderer
        self.liveMatte = liveMatte
    }

    /// Solo trabaja en modo A con la cámara en vivo. Al apagarse olvida el último mapa.
    var isEnabled: Bool {
        get { state.withLockUnchecked { $0.isEnabled } }
        set {
            state.withLockUnchecked { state in
                state.isEnabled = newValue
                if !newValue { state.frame = nil }
            }
        }
    }

    /// El bokeh actual (apertura y punto tocado), para elegir el plano de foco de cada mapa.
    var bokeh: Bokeh? {
        get { state.withLockUnchecked { $0.bokeh } }
        set { state.withLockUnchecked { $0.bokeh = newValue } }
    }

    var frame: Frame? {
        state.withLockUnchecked { $0.frame }
    }

    /// Se llama desde la cola de profundidad de la cámara con cada mapa. Si no toca, no hace nada.
    func process(_ depthData: AVDepthData) {
        let bokeh = state.withLockUnchecked { state -> Bokeh? in
            guard state.isEnabled, !state.isBusy, let bokeh = state.bokeh else { return nil }
            let now = ContinuousClock.now
            if let last = state.lastStart, now - last < Self.interval { return nil }
            state.isBusy = true
            state.lastStart = now
            return bokeh
        }
        guard let bokeh else { return }
        nonisolated(unsafe) let depthData = depthData
        queue.async { [self] in
            // Los cuadros del visor salen girados a vertical; si el mapa viene apaisado, se gira igual.
            let map = depthData.depthDataMap
            let landscape = CVPixelBufferGetWidth(map) > CVPixelBufferGetHeight(map)
            let depth = DepthMap(depthData: depthData, orientation: landscape ? .right : .up)
            let focus = depth?.focus(for: bokeh, matte: liveMatte.matte)
            let texture = depth.flatMap { try? renderer.makeTexture(depth: $0) }
            state.withLockUnchecked { state in
                state.isBusy = false
                guard state.isEnabled else { return }
                if let texture, let focus {
                    state.frame = Frame(texture: texture, focus: focus)
                }
            }
        }
    }
}

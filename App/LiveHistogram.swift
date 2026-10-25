import CoreVideo
import Foundation
import os

/// Histograma de brillo del visor en vivo: toma algunos cuadros (no todos) y cuenta, sobre una muestra
/// de los píxeles, cuántos caen en cada nivel.
final class LiveHistogram: @unchecked Sendable {
    private struct State {
        var isEnabled = false
        var lastStart: ContinuousClock.Instant?
        var handler: (@MainActor @Sendable ([Float]) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// Cada cuánto, como mucho, se recalcula (unas 8 veces por segundo).
    private static let interval = Duration.milliseconds(125)
    static let binCount = 64
    /// Se mira un píxel de cada `step` en cada dirección.
    private static let step = 8

    var isEnabled: Bool {
        get { state.withLockUnchecked { $0.isEnabled } }
        set { state.withLockUnchecked { $0.isEnabled = newValue } }
    }

    /// Recibe cada histograma nuevo (en el main actor): `binCount` valores 0…1 (1 = el nivel más poblado).
    func setHandler(_ handler: (@MainActor @Sendable ([Float]) -> Void)?) {
        state.withLockUnchecked { $0.handler = handler }
    }

    /// Se llama desde la cola de video con cada cuadro BGRA.
    func process(_ frame: CVPixelBuffer) {
        let handler = state.withLockUnchecked { state -> (@MainActor @Sendable ([Float]) -> Void)? in
            guard state.isEnabled, let handler = state.handler else { return nil }
            let now = ContinuousClock.now
            if let last = state.lastStart, now - last < Self.interval { return nil }
            state.lastStart = now
            return handler
        }
        guard let handler, let bins = Self.histogram(of: frame) else { return }
        Task { @MainActor in handler(bins) }
    }

    /// Brillo (luminancia de los valores codificados, como se ven) por niveles.
    static func histogram(of frame: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
        var counts = [Int](repeating: 0, count: binCount)
        for y in stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: step) {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                counts[min(binCount - 1, luma * binCount / 256)] += 1
            }
        }
        let peak = Float(counts.max() ?? 1)
        return counts.map { Float($0) / max(peak, 1) }
    }
}

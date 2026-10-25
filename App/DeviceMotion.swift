import CaptureCore
import CoreMotion
import Observation

/// Cómo está sostenido el teléfono, del acelerómetro, unas 30 veces por segundo. La gravedad se suaviza
/// un poco para que el nivel no tiemble.
@MainActor
@Observable
final class DeviceMotion {
    private(set) var tilt = DeviceTilt.upright
    /// Se llama cuando el teléfono pasa de vertical a horizontal (o al revés).
    @ObservationIgnored var onOrientationChange: (() -> Void)?

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var gravity = SIMD3<Double>(0, -1, 0)
    /// Cuánto pesa cada lectura nueva (el resto, la anterior).
    private static let smoothing = 0.25

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let reading = motion?.gravity else { return }
            let sample = SIMD3(reading.x, reading.y, reading.z)
            MainActor.assumeIsolated { self?.update(sample) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func update(_ sample: SIMD3<Double>) {
        gravity += (sample - gravity) * Self.smoothing
        let previous = tilt.orientation
        tilt = DeviceTilt.from(gravityX: gravity.x, y: gravity.y, z: gravity.z, previous: previous)
        if tilt.orientation != previous { onOrientationChange?() }
    }
}

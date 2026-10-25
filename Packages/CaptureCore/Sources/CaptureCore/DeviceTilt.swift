import CoreGraphics
import Foundation

/// Cómo está sostenido el teléfono, a partir de la gravedad del acelerómetro (`CMDeviceMotion.gravity`,
/// en coordenadas del teléfono: x a la derecha, y hacia arriba, z hacia la persona). La pantalla de la
/// app no gira: lo que se dibuja (histograma, nivel, el sol del foco) se gira con `uiRotation`.
public struct DeviceTilt: Sendable, Equatable {
    public enum Orientation: Sendable, Equatable, CaseIterable {
        case portrait
        /// Girado a la izquierda: la parte de arriba del teléfono, a la izquierda.
        case landscapeCounterclockwise
        /// Girado a la derecha: la parte de arriba del teléfono, a la derecha.
        case landscapeClockwise
        case upsideDown

        /// Ángulo de la gravedad (ver `angle`) con el teléfono derecho en esta orientación.
        public var reference: Double {
            switch self {
            case .portrait: 0
            case .landscapeClockwise: 90
            case .upsideDown: 180
            case .landscapeCounterclockwise: -90
            }
        }

        /// Cuánto girar (grados, en sentido horario) lo que se dibuja para que se lea derecho.
        public var uiRotation: Double { -reference }

        public var isLandscape: Bool {
            self == .landscapeClockwise || self == .landscapeCounterclockwise
        }

        /// Giro de la foto (`AVCaptureConnection.videoRotationAngle`) para que salga derecha sostenida
        /// así. El sensor de la cámara trasera está apaisado como con el teléfono girado a la izquierda.
        public var captureRotationAngle: Double {
            switch self {
            case .landscapeCounterclockwise: 0
            case .portrait: 90
            case .landscapeClockwise: 180
            case .upsideDown: 270
            }
        }

        /// Un punto 0…1 del visor (vertical: así se ve en la pantalla, que no gira) en la foto sacada
        /// con el teléfono sostenido así (ver `captureRotationAngle`).
        public func photoPoint(fromFrame point: CGPoint) -> CGPoint {
            switch self {
            case .portrait: point
            case .landscapeCounterclockwise: CGPoint(x: point.y, y: 1 - point.x)
            case .landscapeClockwise: CGPoint(x: 1 - point.y, y: point.x)
            case .upsideDown: CGPoint(x: 1 - point.x, y: 1 - point.y)
            }
        }
    }

    public var orientation: Orientation
    /// Ángulo de la gravedad sobre la pantalla, en grados: 0 con el teléfono vertical y derecho,
    /// positivo si se gira en sentido horario.
    public var angle: Double
    /// Cuánto está torcido respecto de su orientación, en grados (−45…45): 0 = derecho.
    public var tilt: Double
    /// Apuntando al piso o al cielo: ahí el nivel no sirve.
    public var isFlat: Bool

    /// Derecho, con menos de medio grado de error de cada lado.
    public var isLevel: Bool { !isFlat && abs(tilt) < Self.levelTolerance }

    public static let levelTolerance = 1.0
    /// Margen para no saltar de orientación cerca de los 45°.
    static let hysteresis = 10.0
    /// Gravedad perpendicular a la pantalla a partir de la cual el teléfono está "acostado".
    static let flatThreshold = 0.9

    public static let upright = DeviceTilt(orientation: .portrait, angle: 0, tilt: 0, isFlat: false)

    /// La orientación cambia solo si el teléfono se giró bastante más allá de los 45° (`previous` es
    /// la que tenía); acostado, se queda con la anterior.
    public static func from(gravityX x: Double, y: Double, z: Double, previous: Orientation) -> DeviceTilt {
        let angle = atan2(x, -y) * 180 / .pi
        let isFlat = abs(z) > flatThreshold
        var orientation = previous
        if !isFlat, distance(angle, previous.reference) > 45 + hysteresis {
            orientation = Orientation.allCases.min { distance(angle, $0.reference) < distance(angle, $1.reference) }
                ?? previous
        }
        let tilt = isFlat ? 0 : signedDifference(angle, orientation.reference)
        return DeviceTilt(orientation: orientation, angle: angle, tilt: tilt, isFlat: isFlat)
    }

    /// `a − b` llevado a −180…180.
    static func signedDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func distance(_ a: Double, _ b: Double) -> Double {
        abs(signedDifference(a, b))
    }
}

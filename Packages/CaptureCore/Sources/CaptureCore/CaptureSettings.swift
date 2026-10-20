import Foundation

/// Programa de exposición.
public enum ExposureProgram: Sendable, Hashable {
    /// P: exposición automática con compensación EV.
    case program
    /// A: prioridad de apertura. El iPhone tiene apertura fija, así que el f-número es *simulado*:
    /// se guarda con la toma para que LensSim genere el bokeh. La exposición sigue siendo automática.
    case aperturePriority(fNumber: Float)
}

public enum WhiteBalanceSetting: Sendable, Hashable {
    case auto
    /// Temperatura en Kelvin y tinte (−150…150, como `AVCaptureDevice.WhiteBalanceTemperatureAndTintValues`).
    case manual(temperature: Float, tint: Float)
}

public enum PhotoFormat: String, Sendable, Hashable, CaseIterable {
    case heic
    /// Apple ProRAW (DNG) + HEIC procesado al lado.
    case proRAW
}

/// Lo que el usuario eligió en la UI. Los valores `nil` significan "automático".
public struct CaptureSettings: Sendable, Hashable {
    public var program: ExposureProgram
    public var exposureBias: Float
    public var iso: Float?
    public var shutterSeconds: Double?
    public var whiteBalance: WhiteBalanceSetting
    public var photoFormat: PhotoFormat

    public init(program: ExposureProgram = .program, exposureBias: Float = 0, iso: Float? = nil,
                shutterSeconds: Double? = nil, whiteBalance: WhiteBalanceSetting = .auto,
                photoFormat: PhotoFormat = .heic) {
        self.program = program
        self.exposureBias = exposureBias
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.whiteBalance = whiteBalance
        self.photoFormat = photoFormat
    }

    /// Paradas de apertura simulada que ofrece el modo A.
    public static let apertureStops: [Float] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]
}

/// Rangos del formato activo de la cámara.
public struct ExposureLimits: Sendable, Hashable {
    public var isoRange: ClosedRange<Float>
    public var shutterRange: ClosedRange<Double>
    public var biasRange: ClosedRange<Float>

    public init(isoRange: ClosedRange<Float>, shutterRange: ClosedRange<Double>, biasRange: ClosedRange<Float>) {
        self.isoRange = isoRange
        self.shutterRange = shutterRange
        self.biasRange = biasRange
    }

    /// Velocidades de obturación "de dial" (1/8000 … 1 s) que entran en el rango del dispositivo.
    public var shutterStops: [Double] {
        let denominators: [Double] = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1]
        return denominators.map { 1 / $0 }.filter(shutterRange.contains)
    }

    /// ISO en tercios de paso a partir de 25 que entran en el rango del dispositivo.
    public var isoStops: [Float] {
        let stops: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                              1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
        return stops.filter(isoRange.contains)
    }
}

/// Cómo se programa la exposición en el dispositivo, resuelto a partir de `CaptureSettings`.
public enum ExposurePlan: Sendable, Equatable {
    case automatic(bias: Float)
    case custom(iso: Float, shutterSeconds: Double)

    /// Si el usuario fijó ISO u obturación pasamos a exposición custom; el valor que quedó en
    /// automático toma el actual de la cámara (AVFoundation exige ambos). Todo se recorta a los
    /// límites del formato activo.
    public static func resolve(_ settings: CaptureSettings, limits: ExposureLimits,
                               currentISO: Float, currentShutterSeconds: Double) -> ExposurePlan {
        guard settings.iso != nil || settings.shutterSeconds != nil else {
            return .automatic(bias: settings.exposureBias.clamped(to: limits.biasRange))
        }
        return .custom(iso: (settings.iso ?? currentISO).clamped(to: limits.isoRange),
                       shutterSeconds: (settings.shutterSeconds ?? currentShutterSeconds).clamped(to: limits.shutterRange))
    }
}

public enum WhiteBalanceMath {
    /// AVFoundation rechaza ganancias fuera de 1…`maxWhiteBalanceGain`.
    public static func clampGains(_ gains: SIMD3<Float>, maxGain: Float) -> SIMD3<Float> {
        gains.clamped(lowerBound: SIMD3(repeating: 1), upperBound: SIMD3(repeating: maxGain))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

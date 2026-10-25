#if os(iOS)
import AVFoundation

import os

public enum CameraError: Error, Equatable {
    case accessDenied
    case noCamera
    case configurationFailed(String)
    case rawUnsupported
    case captureFailed(String)
    case photoLibraryDenied
}

/// Lo que la cámara soporta, para que la UI muestre solo opciones válidas.
public struct CameraCapabilities: Sendable, Hashable {
    public var isProRAWSupported: Bool
    /// ProRAW o, si no, el RAW del sensor (Bayer).
    public var isRAWSupported: Bool
    public var limits: ExposureLimits
    /// Focal equivalente en 35 mm del lente (por diagonal), para los recortes por focal.
    public var equivalentFocalLength: Double
    /// Las fotos traen el mapa de profundidad (cámara combinada con LiDAR o doble).
    public var hasDepth: Bool = false

    /// Focal equivalente (diagonal de 43,27 mm) de un sensor 4:3 con este campo de visión
    /// horizontal en grados: el ancho de un 4:3 con esa diagonal mide 34,6 mm.
    public static func equivalentFocalLength(horizontalFieldOfView degrees: Double) -> Double {
        17.3 / tan(degrees * .pi / 360)
    }
}

/// Resultado de una toma: la imagen procesada (JPG o HEIC) y, si se pidió RAW, el DNG.
public struct CapturedPhoto: Sendable {
    public var processed: Data?
    public var raw: Data?
    public var settings: CaptureSettings
}

/// Sesión de captura con AVFoundation: cámara trasera gran angular, frames BGRA para el preview
/// y `AVCapturePhotoOutput` para HEIC/ProRAW. Todo el estado de la sesión se toca en `sessionQueue`.
public final class CameraController: NSObject, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capturecore.session")
    private let videoQueue = DispatchQueue(label: "capturecore.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Profundidad en vivo (cámara con LiDAR o doble), para el bokeh del visor.
    private let depthOutput = AVCaptureDepthDataOutput()
    private let depthQueue = DispatchQueue(label: "capturecore.depth", qos: .userInitiated)
    private let depthHandler = OSAllocatedUnfairLock<(@Sendable (AVDepthData) -> Void)?>(initialState: nil)
    private var device: AVCaptureDevice?
    private let frameHandler = OSAllocatedUnfairLock<(@Sendable (CVPixelBuffer) -> Void)?>(initialState: nil)
    private let inFlight = OSAllocatedUnfairLock(initialState: [Int64: PhotoCaptureDelegate]())

    public override init() {
        super.init()
    }

    public static var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    /// Cámaras que miden profundidad y en las que el zoom 1× es la principal (en la triple y la
    /// doble gran angular, 1× es la ultra gran angular).
    private static let depthCameraTypes: [AVCaptureDevice.DeviceType] = [.builtInLiDARDepthCamera, .builtInDualCamera]

    /// Con `depth`, una cámara que mide profundidad (si el iPhone tiene); si no, la principal sola,
    /// que es la que da ProRAW.
    private static func backCamera(depth: Bool) -> AVCaptureDevice? {
        if depth {
            for type in depthCameraTypes {
                if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Se llama en la cola de video con cada frame BGRA (ya rotado a vertical).
    public func setFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        frameHandler.withLock { $0 = handler }
    }

    /// Se llama en una cola propia con cada mapa de profundidad en vivo (solo en modo A, con una cámara
    /// que la mide). Puede venir apaisado: ver `AVDepthData.applyingExifOrientation`.
    public func setDepthHandler(_ handler: (@Sendable (AVDepthData) -> Void)?) {
        depthHandler.withLock { $0 = handler }
    }

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Configuración

    /// Arma la sesión. Con `depth` (modo A) usa una cámara que mide profundidad, para el bokeh; sin
    /// `depth` (modo P), la principal sola, con ProRAW.
    public func configure(depth: Bool = false) async throws -> CameraCapabilities {
        try await onSessionQueue { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo

            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed("photo output") }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed("video output") }
            session.addOutput(videoOutput)

            return try attachCamera(depth: depth)
        }
    }

    /// Cambia de cámara: con profundidad (modo A) o la principal con ProRAW (modo P). El visor se
    /// reconfigura (tarda un momento). Hay que volver a aplicar la exposición después.
    public func setDepthMode(_ depth: Bool) async throws -> CameraCapabilities {
        try await onSessionQueue { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            return try attachCamera(depth: depth)
        }
    }

    /// Pone la cámara de entrada (sacando la anterior) y ajusta las salidas. En `sessionQueue`, dentro
    /// de `beginConfiguration`.
    private func attachCamera(depth: Bool) throws -> CameraCapabilities {
        guard let device = Self.backCamera(depth: depth) else { throw CameraError.noCamera }
        if device != self.device {
            for input in session.inputs {
                session.removeInput(input)
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configurationFailed("input") }
            session.addInput(input)
        }

        // Profundidad y recorte de retrato de Apple, guardados dentro del JPG/HEIC (para el bokeh).
        // Cada cambio de cámara puede cambiar lo que se puede; se vuelve a pedir todo.
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliverySupported
        // Recortes finos de pelo y anteojos, para los bordes del bokeh.
        photoOutput.enabledSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            .filter { [.hair, .glasses].contains($0) }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        // Profundidad también en vivo, para que el visor muestre el mismo bokeh que la foto.
        if photoOutput.isDepthDataDeliveryEnabled {
            if !session.outputs.contains(depthOutput), session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                depthOutput.isFilteringEnabled = true
                depthOutput.alwaysDiscardsLateDepthData = true
                depthOutput.setDelegate(self, callbackQueue: depthQueue)
            }
        } else if session.outputs.contains(depthOutput) {
            session.removeOutput(depthOutput)
        }
        // La cámara combinada no tiene que pasar sola a otra (por ejemplo, al tele con poca luz).
        if device.primaryConstituentDeviceSwitchingBehavior != .unsupported, (try? device.lockForConfiguration()) != nil {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
            device.unlockForConfiguration()
        }

        // UI fija en vertical: el preview y las fotos salen rotados 90°.
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video),
                           depthOutput.connection(with: .depthData)] {
            if let connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        self.device = device
        return CameraCapabilities(
            isProRAWSupported: photoOutput.isAppleProRAWEnabled,
            isRAWSupported: !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty,
            limits: Self.limits(of: device),
            equivalentFocalLength: CameraCapabilities.equivalentFocalLength(
                horizontalFieldOfView: Double(device.activeFormat.videoFieldOfView)),
            hasDepth: photoOutput.isDepthDataDeliveryEnabled)
    }

    static func limits(of device: AVCaptureDevice) -> ExposureLimits {
        let format = device.activeFormat
        return ExposureLimits(
            isoRange: format.minISO...format.maxISO,
            shutterRange: format.minExposureDuration.seconds...format.maxExposureDuration.seconds,
            biasRange: device.minExposureTargetBias...device.maxExposureTargetBias)
    }

    public func start() {
        sessionQueue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    public func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Exposición y balance de blancos

    public func apply(_ settings: CaptureSettings) async throws {
        try await onSessionQueue { [self] in
            guard let device else { throw CameraError.noCamera }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let plan = ExposurePlan.resolve(settings, limits: Self.limits(of: device),
                                            currentISO: device.iso,
                                            currentShutterSeconds: device.exposureDuration.seconds)
            switch plan {
            case .automatic(let bias):
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(bias, completionHandler: nil)
            case .custom(let iso, let shutter):
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000),
                                                 iso: iso, completionHandler: nil)
                }
            }

            switch settings.whiteBalance {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case .manual(let temperature, let tint):
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { break }
                let gains = device.deviceWhiteBalanceGains(
                    for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint))
                let clamped = WhiteBalanceMath.clampGains(SIMD3(gains.redGain, gains.greenGain, gains.blueGain),
                                                          maxGain: device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(
                    with: AVCaptureDevice.WhiteBalanceGains(redGain: clamped.x, greenGain: clamped.y, blueGain: clamped.z),
                    completionHandler: nil)
            }
        }
    }

    // MARK: - Foco por toque

    /// Enfoca y mide la luz en `point` (coordenadas del sensor, ver `FocusGeometry`). El foco queda
    /// fijo ahí hasta otro toque o `resetFocus()`; con exposición manual (ISO u obturación fijos) solo
    /// se mueve el foco.
    public func focus(at point: CGPoint) async throws {
        try await onSessionQueue { [self] in
            guard let device else { throw CameraError.noCamera }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.exposureMode != .custom,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Vuelve al foco y la exposición automáticos sobre todo el cuadro.
    public func resetFocus() async throws {
        try await onSessionQueue { [self] in
            guard let device else { throw CameraError.noCamera }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = center
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.exposureMode != .custom,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = center
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    // MARK: - Captura

    /// `rotationAngle`: cómo girar la foto para que salga derecha según cómo se sostiene el teléfono
    /// (ver `DeviceTilt.Orientation.captureRotationAngle`); 90 = vertical.
    public func capturePhoto(settings: CaptureSettings, rotationAngle: Double = 90) async throws -> CapturedPhoto {
        let (processed, raw) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Data?), Error>) in
            sessionQueue.async { [self, inFlight] in
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(CGFloat(rotationAngle)) {
                    connection.videoRotationAngle = CGFloat(rotationAngle)
                }
                let photoSettings: AVCapturePhotoSettings
                do {
                    photoSettings = try makePhotoSettings(for: settings.photoFormat)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let id = photoSettings.uniqueID
                // AVFoundation no retiene el delegate: lo guardamos hasta que termine la toma.
                let delegate = PhotoCaptureDelegate { result in
                    inFlight.withLock { _ = $0.removeValue(forKey: id) }
                    continuation.resume(with: result)
                }
                inFlight.withLock { $0[id] = delegate }
                photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
            }
        }
        return CapturedPhoto(processed: processed, raw: raw, settings: settings)
    }

    private func makePhotoSettings(for format: PhotoFormat) throws -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType? = switch format.processed {
        case .heic: photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        case .jpeg: .jpeg
        case nil: nil
        }
        let processed: [String: Any]? = codec.map { [AVVideoCodecKey: $0] }
        guard format.includesRAW else {
            let settings = processed.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            requestDepth(settings)
            return settings
        }
        // ProRAW si está; si no, el RAW del sensor (Bayer).
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let proRAW = photoOutput.isAppleProRAWEnabled ? rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) : nil
        guard let rawType = proRAW ?? rawTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
            throw CameraError.rawUnsupported
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processed)
        // El RAW Bayer no admite el procesado de máxima calidad.
        settings.photoQualityPrioritization = proRAW == nil ? .speed : .quality
        if processed != nil { requestDepth(settings) }
        return settings
    }

    /// Pide la profundidad (y el recorte de retrato) dentro de la foto procesada, si la cámara la da.
    private func requestDepth(_ settings: AVCapturePhotoSettings) {
        guard photoOutput.isDepthDataDeliveryEnabled else { return }
        settings.isDepthDataDeliveryEnabled = true
        settings.embedsDepthDataInPhoto = true
        if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
            settings.isPortraitEffectsMatteDeliveryEnabled = true
            settings.embedsPortraitEffectsMatteInPhoto = true
        }
        if !photoOutput.enabledSemanticSegmentationMatteTypes.isEmpty {
            settings.enabledSemanticSegmentationMatteTypes = photoOutput.enabledSemanticSegmentationMatteTypes
            settings.embedsSemanticSegmentationMattesInPhoto = true
        }
    }
}

extension CameraController: AVCaptureDepthDataOutputDelegate {
    public func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                                timestamp: CMTime, connection: AVCaptureConnection) {
        depthHandler.withLock { $0 }?(depthData)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let handler = frameHandler.withLock({ $0 })
        else { return }
        handler(pixelBuffer)
    }
}

/// Junta las representaciones de una toma (HEIC y/o DNG) y avisa al terminar.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var processed: Data?
    private var raw: Data?
    private var error: Error?
    private let completion: (Result<(Data?, Data?), Error>) -> Void

    init(completion: @escaping (Result<(Data?, Data?), Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            self.error = error
        } else if photo.isRawPhoto {
            raw = photo.fileDataRepresentation()
        } else {
            processed = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error = error ?? self.error {
            completion(.failure(error))
        } else if processed == nil && raw == nil {
            completion(.failure(CameraError.captureFailed("sin datos")))
        } else {
            completion(.success((processed, raw)))
        }
    }
}
#endif

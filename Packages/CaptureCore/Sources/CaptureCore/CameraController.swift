#if os(iOS)
import AVFoundation
import os

public enum CameraError: Error, Equatable {
    case accessDenied
    case noCamera
    case configurationFailed(String)
    case proRAWUnsupported
    case captureFailed(String)
    case photoLibraryDenied
}

/// Lo que la cámara soporta, para que la UI muestre solo opciones válidas.
public struct CameraCapabilities: Sendable, Hashable {
    public var isProRAWSupported: Bool
    public var limits: ExposureLimits
}

/// Resultado de una toma: HEIC procesado y, si se pidió ProRAW, el DNG.
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
    private var device: AVCaptureDevice?
    private let frameHandler = OSAllocatedUnfairLock<(@Sendable (CVPixelBuffer) -> Void)?>(initialState: nil)
    private let inFlight = OSAllocatedUnfairLock(initialState: [Int64: PhotoCaptureDelegate]())

    public override init() {
        super.init()
    }

    public static var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
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

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Configuración

    public func configure() async throws -> CameraCapabilities {
        try await onSessionQueue { [self] in
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw CameraError.noCamera
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configurationFailed("input") }
            session.addInput(input)

            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed("photo output") }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed("video output") }
            session.addOutput(videoOutput)

            // UI fija en vertical: el preview y las fotos salen rotados 90°.
            for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
                if let connection, connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }

            self.device = device
            return CameraCapabilities(isProRAWSupported: photoOutput.isAppleProRAWEnabled, limits: Self.limits(of: device))
        }
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

    // MARK: - Captura

    public func capturePhoto(settings: CaptureSettings) async throws -> CapturedPhoto {
        let (processed, raw) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Data?), Error>) in
            sessionQueue.async { [self, inFlight] in
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
        let hevc: [String: Any]? = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
        let settings: AVCapturePhotoSettings
        switch format {
        case .heic:
            settings = hevc.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
        case .proRAW:
            guard photoOutput.isAppleProRAWEnabled,
                  let rawType = photoOutput.availableRawPhotoPixelFormatTypes
                    .first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
            else { throw CameraError.proRAWUnsupported }
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: hevc)
        }
        settings.photoQualityPrioritization = .quality
        return settings
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

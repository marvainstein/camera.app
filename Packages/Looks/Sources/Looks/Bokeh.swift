import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Vision

/// Desenfoque del fondo que simula una apertura (modo A). El iPhone tiene apertura fija, así que el
/// f-número solo decide cuánto se desenfoca lo que no es la persona: como en una lente real, el
/// tamaño de los discos de bokeh es inversamente proporcional al f-número.
///
/// La forma del bokeh es sintética y propia (ver `BokehShaders`): disco que, al cerrar el diafragma,
/// muestra las hojas, y que hacia los bordes del cuadro se recorta en "ojo de gato".
public struct Bokeh: Codable, Sendable, Hashable {
    public var fNumber: Float
    /// Punto que queda nítido (tocado en el visor), en coordenadas 0…1 de la foto derecha y entera
    /// (sin el recorte por focal). nil = automático: la persona o, si no hay, el centro.
    public var focus: FocusPoint?
    /// Disparidad (1/m) donde enfocó la lente al sacar la foto, si se tocó para enfocar. Al editar, lo
    /// que está muy lejos de ahí no puede quedar nítido (ya salió desenfocado).
    public var capturedFocus: Float?

    public init(fNumber: Float, focus: FocusPoint? = nil, capturedFocus: Float? = nil) {
        self.fNumber = fNumber
        self.focus = focus
        self.capturedFocus = capturedFocus
    }

    /// Diferencia (en 1/m) a partir de la cual algo que estaba fuera del foco de la lente ya se ve
    /// borroso en el iPhone: no se puede volver nítido al editar.
    public static let opticalFocusTolerance: Float = 0.5

    /// Un punto en coordenadas 0…1.
    public struct FocusPoint: Codable, Sendable, Hashable {
        public var x: Float
        public var y: Float

        public init(x: Float, y: Float) {
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
        }
    }

    /// Radio de los discos a f/1.4, en fracción del lado corto de la foto.
    static let radiusAtF14: Float = 0.022
    /// Por debajo de este radio (en píxeles de la foto) el desenfoque no se nota: no se aplica.
    static let minimumRadius: Float = 1.5
    /// Hojas del diafragma.
    static let blades: Float = 9
    /// Cuánto se recorta el disco hacia las esquinas (ojo de gato), 0…1.
    static let catEye: Float = 0.35
    /// Peso extra de las luces fuertes, para que formen discos brillantes.
    static let highlightGain: Float = 6
    /// Con profundidad: hasta cuántas dioptrías (1/m) de diferencia con el foco crece el desenfoque
    /// (por ejemplo, algo a 25 cm con el foco en el infinito); más allá queda igual.
    static let depthMaxDiopters: Float = 4

    /// Radio de los discos en fracción del lado corto de la foto.
    public var radiusFraction: Float {
        Self.radiusAtF14 * 1.4 / max(fNumber, 1)
    }

    /// Radio de los discos en píxeles, para una foto con ese lado corto.
    public func radius(shortSide: Int) -> Float {
        radiusFraction * Float(shortSide)
    }

    /// Con profundidad: radio del desenfoque, en píxeles de la foto entera (sin recortar), por cada
    /// dioptría (1/m) de diferencia con el plano de foco. Es el de una lente real: en un sensor de
    /// 35 mm el diámetro es f² · Δ / N, y simular una focal `focalLength` recortando una foto sacada a
    /// `lensFocalLength` agranda todo en `focalLength / lensFocalLength`. Por ejemplo, 24 mm a f/1.4
    /// da un 0,86 % del lado corto por dioptría, y 50 mm, más del doble.
    public func depthRadiusPerDiopter(shortSide: Int, focalLength: Double, lensFocalLength: Double) -> Float {
        Float(shortSide) * Float(focalLength) * Float(lensFocalLength) / (48_000 * max(fNumber, 1))
    }

    /// Si en una imagen con ese lado corto el desenfoque se nota (si no, no vale la pena aplicarlo).
    public func isVisible(shortSide: Int) -> Bool {
        radius(shortSide: shortSide) >= Self.minimumRadius
    }

    /// Qué tan redondos son los discos: 1 = círculo (abierto), 0 = polígono de las hojas (desde f/4).
    var roundness: Float {
        min(max((4 - fNumber) / 2.6, 0), 1)
    }

    /// Escala de la versión reducida sobre la que se desenfoca, para que el radio quede en
    /// `quality.workRadius` píxeles como máximo (el desenfoque grande a resolución completa sería
    /// lento y no se distingue del hecho sobre una versión reducida).
    static func workScale(radius: Float, quality: BokehQuality = .photo) -> Float {
        min(1, quality.workRadius / max(radius, 1))
    }

    /// Con profundidad hay desenfoques de todos los tamaños: la versión reducida es más grande.
    static func depthWorkScale(radius: Float, quality: BokehQuality) -> Float {
        min(1, quality.depthWorkRadius / max(radius, 1))
    }
}

/// Definición del bokeh. El visor usa el mismo algoritmo y el mismo radio que la foto, con menos
/// detalle, para que lo que se ve antes de disparar sea lo que sale.
public enum BokehQuality: Sendable {
    /// Foto final.
    case photo
    /// Visor en vivo (30 cuadros por segundo).
    case preview

    /// Radio máximo, en píxeles de la versión reducida sobre la que se desenfoca.
    var workRadius: Float {
        switch self {
        case .photo: 16
        case .preview: 8
        }
    }

    /// Puntos de la espiral que llena el disco.
    var sampleCount: UInt32 {
        switch self {
        case .photo: 160
        case .preview: 64
        }
    }

    /// Con profundidad hacen falta más puntos: cada uno tiene su propio desenfoque.
    var depthSampleCount: UInt32 {
        switch self {
        case .photo: 400
        case .preview: 128
        }
    }

    /// Radio máximo en la versión reducida, con profundidad.
    var depthWorkRadius: Float {
        switch self {
        case .photo: 32
        case .preview: 12
        }
    }
}

/// Texturas intermedias del bokeh, para no crearlas en cada cuadro del visor.
public final class BokehScratch: @unchecked Sendable {
    var prepared: MTLTexture?
    var blurred: MTLTexture?
    var coc: MTLTexture?

    public init() {}
}

/// Qué parte de la foto es una persona, según Vision: 0 = fondo, 255 = persona. Está "derecha"
/// (con la orientación EXIF de la foto ya aplicada), como se ve la foto.
public struct PersonMatte: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "matte de \(width)×\(height) con \(pixels.count) píxeles")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Por debajo de esta fracción de la imagen, no hay una persona (lo que queda es ruido).
    static let minimumCoverage: Float = 0.01

    /// Fracción de la imagen que es persona.
    public var coverage: Float {
        guard !pixels.isEmpty else { return 0 }
        return Float(pixels.lazy.filter { $0 >= 128 }.count) / Float(pixels.count)
    }

    /// Lado largo de la imagen que se le pasa a Vision: más no mejora el recorte y tarda más.
    static let detectionSize = 1536

    /// Recorte de la persona de una foto (HEIC/JPEG). nil si no hay una persona o si Vision no pudo
    /// (por ejemplo, en el simulador).
    public static func detect(inPhoto data: Data) -> PersonMatte? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: detectionSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return detect(in: upright)
    }

    /// El mejor recorte disponible de una foto: el que guardó el iPhone al sacarla (ver
    /// `load(fromPhoto:)`) o, si no tiene, el de Vision.
    public static func best(inPhoto data: Data) -> PersonMatte? {
        load(fromPhoto: data) ?? detect(inPhoto: data)
    }

    /// Los recortes que guardó el iPhone dentro de la foto al sacarla: el de retrato (persona entera,
    /// más fino que el de Vision) sumado a los de pelo y anteojos, que siguen los mechones y los
    /// marcos. Derecho, del tamaño del de retrato. nil si la foto no tiene recorte de retrato.
    public static func load(fromPhoto data: Data) -> PersonMatte? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        func info(_ type: CFString) -> [AnyHashable: Any]? {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any]
        }
        guard let portraitInfo = info(kCGImageAuxiliaryDataTypePortraitEffectsMatte),
              var portrait = try? AVPortraitEffectsMatte(fromDictionaryRepresentation: portraitInfo)
        else { return nil }
        if orientation != .up { portrait = portrait.applyingExifOrientation(orientation) }
        guard let base = PersonMatte(pixelBuffer: portrait.mattingImage) else { return nil }
        let details = Self.detailTypes.compactMap { type -> PersonMatte? in
            guard let detailInfo = info(type),
                  var matte = try? AVSemanticSegmentationMatte(fromImageSourceAuxiliaryDataType: type,
                                                               dictionaryRepresentation: detailInfo)
            else { return nil }
            if orientation != .up { matte = matte.applyingExifOrientation(orientation) }
            return PersonMatte(pixelBuffer: matte.mattingImage)
        }
        let combined = base.combined(with: details)
        return combined.coverage >= minimumCoverage ? combined : nil
    }

    /// Recortes finos que se suman al de retrato: lo que el recorte general suele perder en los bordes.
    static var detailTypes: [CFString] {
        [kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte]
    }

    /// El máximo de este recorte y los otros (que pueden tener otro tamaño), punto por punto, del
    /// tamaño de este.
    func combined(with others: [PersonMatte]) -> PersonMatte {
        guard !others.isEmpty else { return self }
        var pixels = self.pixels
        for other in others {
            for y in 0..<height {
                let oy = min(other.height - 1, y * other.height / height)
                for x in 0..<width {
                    let ox = min(other.width - 1, x * other.width / width)
                    pixels[y * width + x] = max(pixels[y * width + x], other.pixels[oy * other.width + ox])
                }
            }
        }
        return PersonMatte(width: width, height: height, pixels: pixels)
    }

    /// Recorte de la persona de una imagen derecha. nil si no hay una persona o si Vision no pudo.
    public static func detect(in image: CGImage) -> PersonMatte? {
        detect(handler: VNImageRequestHandler(cgImage: image, options: [:]), quality: .accurate)
    }

    /// Recorte de la persona de un cuadro del visor (derecho). Con `.balanced`, Vision tarda unos
    /// milisegundos: sirve para el visor en vivo. nil si no hay una persona o si Vision no pudo.
    public static func detect(inFrame frame: CVPixelBuffer,
                              quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) -> PersonMatte? {
        detect(handler: VNImageRequestHandler(cvPixelBuffer: frame, options: [:]), quality: quality)
    }

    private static func detect(handler: VNImageRequestHandler,
                               quality: VNGeneratePersonSegmentationRequest.QualityLevel) -> PersonMatte? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer,
              let matte = PersonMatte(pixelBuffer: buffer),
              matte.coverage >= minimumCoverage
        else { return nil }
        return matte
    }

    /// Mezcla con el recorte del cuadro anterior (`weight` = cuánto pesa este), para que el borde de
    /// la persona no titile en el visor. Si los tamaños no coinciden, queda este.
    public func blended(withPrevious previous: PersonMatte?, weight: Float) -> PersonMatte {
        guard let previous, previous.width == width, previous.height == height else { return self }
        let w = min(max(weight, 0), 1)
        let mixed = zip(pixels, previous.pixels).map { new, old in
            UInt8((Float(new) * w + Float(old) * (1 - w)).rounded())
        }
        return PersonMatte(width: width, height: height, pixels: mixed)
    }

    init?(pixelBuffer buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                pixels[y * width + x] = row[x]
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// Debe coincidir con `BokehUniforms` en BokehShaders.swift.
struct BokehUniforms {
    var sourceSize: SIMD2<Float>
    var workSize: SIMD2<Float>
    var radius: Float
    var blades: Float
    var roundness: Float
    var catEye: Float
    var highlightGain: Float
    var sampleCount: UInt32
    /// Coordenadas del matte (derecho) a partir de las de la foto guardada: x = dot(matteX, (u, v, 1)).
    var matteX: SIMD4<Float>
    var matteY: SIMD4<Float>
}

extension LookRenderer {
    /// Sube el recorte de persona como textura `.r8Unorm`.
    public func makeTexture(matte: PersonMatte) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: matte.width, height: matte.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        return try upload(matte.pixels, descriptor: descriptor, bytesPerPixel: 1)
    }

    /// Desenfoca todo lo que no es la persona. `orientation` es la orientación EXIF de `image` (el
    /// matte está derecho). Si el desenfoque no se notaría, devuelve la imagen sin tocar.
    public func applyBokeh(_ bokeh: Bokeh, to image: CGImage, matte: PersonMatte, orientation: Int) throws -> CGImage {
        guard bokeh.isVisible(shortSide: min(image.width, image.height)) else { return image }
        let (source, colorSpace) = try makeTexture(image: image)
        let target = try makeRenderTarget(width: image.width, height: image.height)
        let matteTexture = try makeTexture(matte: matte)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LookRendererError.resourceCreationFailed("command buffer")
        }
        try encodeBokeh(commandBuffer: commandBuffer, source: source, matte: matteTexture, destination: target,
                        bokeh: bokeh, orientation: orientation)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try makeImage(texture: target, colorSpace: colorSpace)
    }

    /// Codifica el bokeh de `source` a `destination` (mismo tamaño): reduce la fuente sacando la
    /// persona, desenfoca con la forma de la apertura y compone la persona nítida encima. `scratch`
    /// guarda las texturas intermedias entre llamadas (para el visor).
    public func encodeBokeh(commandBuffer: MTLCommandBuffer, source: MTLTexture, matte: MTLTexture,
                            destination: MTLTexture, bokeh: Bokeh, orientation: Int,
                            quality: BokehQuality = .photo, scratch: BokehScratch? = nil) throws {
        let radius = bokeh.radius(shortSide: min(source.width, source.height))
        let scale = Bokeh.workScale(radius: radius, quality: quality)
        let workWidth = max(1, Int((Float(source.width) * scale).rounded()))
        let workHeight = max(1, Int((Float(source.height) * scale).rounded()))
        let prepared = try workTexture(scratch?.prepared, width: workWidth, height: workHeight)
        let blurred = try workTexture(scratch?.blurred, width: workWidth, height: workHeight)
        scratch?.prepared = prepared
        scratch?.blurred = blurred

        let transform = Framing.displayedPointTransform(orientation: orientation)
        var uniforms = BokehUniforms(
            sourceSize: SIMD2(Float(source.width), Float(source.height)),
            workSize: SIMD2(Float(workWidth), Float(workHeight)),
            radius: radius * scale,
            blades: Bokeh.blades,
            roundness: bokeh.roundness,
            catEye: Bokeh.catEye,
            highlightGain: Bokeh.highlightGain,
            sampleCount: quality.sampleCount,
            matteX: SIMD4(transform.x, 0),
            matteY: SIMD4(transform.y, 0))

        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_prepare", textures: [source, matte],
                            target: prepared, uniforms: &uniforms)
        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_gather", textures: [prepared],
                            target: blurred, uniforms: &uniforms)
        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_composite",
                            textures: [source, blurred, matte], target: destination, uniforms: &uniforms)
    }

    /// `existing` si tiene ese tamaño y formato; si no, una nueva.
    func workTexture(_ existing: MTLTexture?, width: Int, height: Int,
                     format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        if let existing, existing.width == width, existing.height == height, existing.pixelFormat == format {
            return existing
        }
        return try makeRenderTarget(width: width, height: height, pixelFormat: format)
    }

    private func encodeBokehPass(commandBuffer: MTLCommandBuffer, fragment: String, textures: [MTLTexture],
                                 target: MTLTexture, uniforms: inout BokehUniforms) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LookRendererError.resourceCreationFailed("render encoder")
        }
        var vertexUniforms = LookUniforms.passThrough
        encoder.setRenderPipelineState(try pipeline(for: target.pixelFormat, fragment: fragment))
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<LookUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BokehUniforms>.stride, index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

extension Framing {
    /// Inversa de `storedRect` para puntos: de coordenadas normalizadas de la imagen guardada (sin
    /// rotar) a las de la imagen derecha, como `x = dot(t.x, (u, v, 1))`, `y = dot(t.y, (u, v, 1))`.
    static func displayedPointTransform(orientation: Int) -> (x: SIMD3<Float>, y: SIMD3<Float>) {
        switch orientation {
        case 3, 4: (SIMD3(-1, 0, 1), SIMD3(0, -1, 1))
        case 6, 5: (SIMD3(0, -1, 1), SIMD3(1, 0, 0))
        case 8, 7: (SIMD3(0, 1, 0), SIMD3(-1, 0, 1))
        default: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }
}

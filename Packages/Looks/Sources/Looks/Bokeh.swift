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

    public init(fNumber: Float) {
        self.fNumber = fNumber
    }

    /// Radio de los discos a f/1.4, en fracción del lado corto de la foto.
    static let radiusAtF14: Float = 0.022
    /// Por debajo de este radio (en píxeles de la foto) el desenfoque no se nota: no se aplica.
    static let minimumRadius: Float = 1.5
    /// Radio máximo, en píxeles de la versión reducida sobre la que se desenfoca.
    static let workRadius: Float = 16
    /// Hojas del diafragma.
    static let blades: Float = 9
    /// Cuánto se recorta el disco hacia las esquinas (ojo de gato), 0…1.
    static let catEye: Float = 0.35
    /// Peso extra de las luces fuertes, para que formen discos brillantes.
    static let highlightGain: Float = 6

    /// Radio de los discos en fracción del lado corto de la foto.
    public var radiusFraction: Float {
        Self.radiusAtF14 * 1.4 / max(fNumber, 1)
    }

    /// Radio de los discos en píxeles, para una foto con ese lado corto.
    public func radius(shortSide: Int) -> Float {
        radiusFraction * Float(shortSide)
    }

    /// Qué tan redondos son los discos: 1 = círculo (abierto), 0 = polígono de las hojas (desde f/4).
    var roundness: Float {
        min(max((4 - fNumber) / 2.6, 0), 1)
    }

    /// Escala de la versión reducida sobre la que se desenfoca, para que el radio quede en
    /// `workRadius` píxeles como máximo (el desenfoque grande a resolución completa sería lento y
    /// no se distingue del hecho sobre una versión reducida).
    static func workScale(radius: Float) -> Float {
        min(1, workRadius / max(radius, 1))
    }
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

    /// Recorte de la persona de una imagen derecha. nil si no hay una persona o si Vision no pudo.
    public static func detect(in image: CGImage) -> PersonMatte? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer,
              let matte = PersonMatte(pixelBuffer: buffer),
              matte.coverage >= minimumCoverage
        else { return nil }
        return matte
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
        guard bokeh.radius(shortSide: min(image.width, image.height)) >= Bokeh.minimumRadius else { return image }
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
    /// persona, desenfoca con la forma de la apertura y compone la persona nítida encima.
    func encodeBokeh(commandBuffer: MTLCommandBuffer, source: MTLTexture, matte: MTLTexture,
                     destination: MTLTexture, bokeh: Bokeh, orientation: Int) throws {
        let radius = bokeh.radius(shortSide: min(source.width, source.height))
        let scale = Bokeh.workScale(radius: radius)
        let workWidth = max(1, Int((Float(source.width) * scale).rounded()))
        let workHeight = max(1, Int((Float(source.height) * scale).rounded()))
        let prepared = try makeRenderTarget(width: workWidth, height: workHeight, pixelFormat: .rgba16Float)
        let blurred = try makeRenderTarget(width: workWidth, height: workHeight, pixelFormat: .rgba16Float)

        let transform = Framing.displayedPointTransform(orientation: orientation)
        var uniforms = BokehUniforms(
            sourceSize: SIMD2(Float(source.width), Float(source.height)),
            workSize: SIMD2(Float(workWidth), Float(workHeight)),
            radius: radius * scale,
            blades: Bokeh.blades,
            roundness: bokeh.roundness,
            catEye: Bokeh.catEye,
            highlightGain: Bokeh.highlightGain,
            matteX: SIMD4(transform.x, 0),
            matteY: SIMD4(transform.y, 0))

        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_prepare", textures: [source, matte],
                            target: prepared, uniforms: &uniforms)
        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_gather", textures: [prepared],
                            target: blurred, uniforms: &uniforms)
        try encodeBokehPass(commandBuffer: commandBuffer, fragment: "bokeh_composite",
                            textures: [source, blurred, matte], target: destination, uniforms: &uniforms)
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

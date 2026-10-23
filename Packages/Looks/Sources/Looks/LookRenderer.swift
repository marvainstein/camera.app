import CoreGraphics
import Metal
import os
import simd

/// Parámetros de render de un Look.
public struct LookParameters: Sendable, Equatable {
    /// 0 = entrada sin tocar, 1 = LUT completo.
    public var intensity: Float
    /// Cantidad de grano, 0…1 (desvío estándar = 0.1 × grain en valores codificados).
    public var grain: Float
    /// Nitidez, claridad y viñeteo.
    public var effects: LookEffects
    /// Tamaño de la celda de grano en milésimas del lado corto de la salida, para que el grano
    /// se vea igual en el preview y en la foto a resolución completa.
    public var grainScale: Float
    /// Semilla del ruido; cambiarla en cada frame anima el grano.
    public var seed: UInt32
    /// Comparar antes/después (solo preview): posición 0…1 de la línea en el cuadro de salida; a la
    /// izquierda se ve la fuente sin tocar. 0 = sin comparar.
    public var split: Float
    /// Marco del recorte (solo preview), en coordenadas normalizadas de la fuente: afuera se oscurece
    /// y el viñeteo se mide sobre el marco. nil = sin recorte.
    public var frame: CGRect?

    public init(intensity: Float = 1, grain: Float = 0, effects: LookEffects = .neutral, grainScale: Float = 1.5,
                seed: UInt32 = 0, split: Float = 0, frame: CGRect? = nil) {
        self.intensity = intensity
        self.grain = grain
        self.effects = effects
        self.grainScale = grainScale
        self.seed = seed
        self.split = split
        self.frame = frame
    }
}

public enum LookRendererError: Error {
    case metalUnavailable
    case resourceCreationFailed(String)
    case unsupportedImage
}

/// Cómo se mapea la fuente sobre el destino.
public enum LookContentMode: Sendable {
    /// Píxel a píxel (fuente y destino del mismo aspecto).
    case stretch
    /// Llena el destino recortando lo que sobre, como `resizeAspectFill`.
    case aspectFill
    /// Muestra la fuente entera dentro del destino, con bandas negras, como `resizeAspect`.
    case aspectFit
}

/// Debe coincidir con `LookUniforms` en LookShaders.swift.
struct LookUniforms {
    var uvTransform: SIMD4<Float>
    var intensity: Float
    var grainAmount: Float
    var grainCell: Float
    var seed: UInt32
    var lutSize: Float
    var hasLUT: UInt32
    var sharpness: Float
    var clarity: Float
    var vignette: Float
    var hasBlur: UInt32
    var halation: Float
    var bloom: Float
    var hasGlow: UInt32
    var split: Float
    var splitWidth: Float
    var frameX: Float
    var frameY: Float
    var frameWidth: Float
    var frameHeight: Float

    /// Para pases auxiliares: la fuente entera sobre el destino, sin efectos.
    static let passThrough = LookUniforms(
        uvTransform: SIMD4(1, 1, 0, 0), intensity: 0, grainAmount: 0, grainCell: 1, seed: 0, lutSize: 1, hasLUT: 0,
        sharpness: 0, clarity: 0, vignette: 0, hasBlur: 0, halation: 0, bloom: 0, hasGlow: 0, split: 0, splitWidth: 0,
        frameX: 0, frameY: 0, frameWidth: 0, frameHeight: 0)
}

/// Aplica un Look (LUT 3D + intensidad + efectos + grano) con Metal. Sirve para el preview en vivo
/// (render a un drawable) y para la foto final (render offscreen de un `CGImage`).
public final class LookRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    let sourceSampler: MTLSamplerState
    private let lutSampler: MTLSamplerState
    private let pipelines = OSAllocatedUnfairLock(initialState: [PipelineKey: MTLRenderPipelineState]())

    struct PipelineKey: Hashable {
        let fragment: String
        let pixelFormat: MTLPixelFormat
    }

    /// Lado corto de la versión reducida de la fuente contra la que se mide el contraste local
    /// (claridad) y de la que salen bloom y halation. Es relativo a la imagen, así que los efectos se
    /// ven igual en el preview y en la foto.
    static let clarityShortSide = 48

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw LookRendererError.metalUnavailable }
        self.device = device
        self.commandQueue = queue
        self.library = try device.makeLibrary(source: LookShaders.source + BokehShaders.source, options: nil)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.rAddressMode = .clampToEdge
        guard let source = device.makeSamplerState(descriptor: sampler),
              let lut = device.makeSamplerState(descriptor: sampler)
        else { throw LookRendererError.resourceCreationFailed("sampler") }
        self.sourceSampler = source
        self.lutSampler = lut
    }

    // MARK: - Recursos

    /// Sube un LUT como textura 3D `.rgba16Float` (privada, vía blit para que funcione también
    /// en el simulador y en Macs Intel).
    public func makeLUTTexture(_ lut: LUT3D) throws -> MTLTexture {
        let n = lut.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        return try upload(lut.texels.withUnsafeBytes { Array($0) }, descriptor: descriptor, bytesPerPixel: 8)
    }

    /// Crea una textura `.rgba8Unorm` a partir de píxeles RGBA de 8 bits.
    public func makeTexture(rgba8 pixels: [UInt8], width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        return try upload(pixels, descriptor: descriptor, bytesPerPixel: 4)
    }

    /// Textura destino para render offscreen.
    public func makeRenderTarget(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LookRendererError.resourceCreationFailed("render target")
        }
        return texture
    }

    /// Lee una textura 2D de 4 bytes por píxel (`.rgba8Unorm` / `.bgra8Unorm`).
    public func readBytes(_ texture: MTLTexture) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw LookRendererError.resourceCreationFailed("readback") }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    func upload(_ bytes: [UInt8], descriptor: MTLTextureDescriptor, bytesPerPixel: Int) throws -> MTLTexture {
        let bytesPerRow = descriptor.width * bytesPerPixel
        let bytesPerImage = bytesPerRow * descriptor.height
        guard bytes.count == bytesPerImage * descriptor.depth,
              let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw LookRendererError.resourceCreationFailed("texture upload") }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerImage,
                  sourceSize: MTLSize(width: descriptor.width, height: descriptor.height, depth: descriptor.depth),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    // MARK: - Render

    func pipeline(for pixelFormat: MTLPixelFormat, fragment: String = "look_fragment") throws -> MTLRenderPipelineState {
        let key = PipelineKey(fragment: fragment, pixelFormat: pixelFormat)
        if let cached = pipelines.withLock({ $0[key] }) { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "look_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines.withLock { $0[key] = state }
        return state
    }

    /// Codifica el Look sobre `destination` (por ejemplo `drawable.texture`).
    public func encode(commandBuffer: MTLCommandBuffer,
                       source: MTLTexture,
                       lut: MTLTexture?,
                       destination: MTLTexture,
                       parameters: LookParameters,
                       contentMode: LookContentMode = .stretch) throws {
        let effects = parameters.effects.clamped
        let needsGlow = effects.halation > 0 || effects.bloom > 0
        let base = try effects.claridad != 0 || needsGlow ? encodeClarityBase(commandBuffer: commandBuffer, source: source) : nil
        let blurred = effects.claridad != 0 ? base : nil
        let glow = try needsGlow ? base.map { try encodeGlow(commandBuffer: commandBuffer, base: $0) } : nil
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LookRendererError.resourceCreationFailed("render encoder")
        }
        let shortSide = Float(min(destination.width, destination.height))
        var uniforms = LookUniforms(
            uvTransform: Self.uvTransform(source: (source.width, source.height),
                                          destination: (destination.width, destination.height),
                                          contentMode: contentMode),
            intensity: simd_clamp(parameters.intensity, 0, 1),
            grainAmount: max(parameters.grain, 0),
            grainCell: parameters.grainScale * shortSide / 1000,
            seed: parameters.seed,
            lutSize: Float(lut?.width ?? 1),
            hasLUT: lut == nil ? 0 : 1,
            sharpness: effects.nitidez,
            clarity: effects.claridad,
            vignette: effects.vineteo,
            hasBlur: blurred == nil ? 0 : 1,
            halation: effects.halation,
            bloom: effects.bloom,
            hasGlow: glow == nil ? 0 : 1,
            split: simd_clamp(parameters.split, 0, 1),
            splitWidth: 3 / Float(max(destination.width, 1)),
            frameX: Float(parameters.frame?.minX ?? 0),
            frameY: Float(parameters.frame?.minY ?? 0),
            frameWidth: Float(parameters.frame?.width ?? 0),
            frameHeight: Float(parameters.frame?.height ?? 0))
        encoder.setRenderPipelineState(try pipeline(for: destination.pixelFormat))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LookUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LookUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(lut, index: 1)
        encoder.setFragmentTexture(blurred, index: 2)
        encoder.setFragmentTexture(glow, index: 3)
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.setFragmentSamplerState(lutSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Reduce la fuente entera (sin recorte) a `clarityShortSide` de lado corto, promediando todo
    /// el área de cada píxel: en rgb, el "entorno" contra el que la claridad mide el contraste local;
    /// en alfa, cuánto de ese área es luz fuerte (base del bloom y la halation).
    private func encodeClarityBase(commandBuffer: MTLCommandBuffer, source: MTLTexture) throws -> MTLTexture {
        let scale = Double(Self.clarityShortSide) / Double(max(1, min(source.width, source.height)))
        let target = try makeRenderTarget(width: max(1, Int((Double(source.width) * scale).rounded())),
                                          height: max(1, Int((Double(source.height) * scale).rounded())),
                                          pixelFormat: .rgba16Float)
        try encodePass(commandBuffer: commandBuffer, fragment: "look_downsample", source: source, target: target)
        return target
    }

    /// Las luces fuertes de la base difuminadas (gaussiano σ = 1.25 píxeles reducidos), del mismo tamaño.
    private func encodeGlow(commandBuffer: MTLCommandBuffer, base: MTLTexture) throws -> MTLTexture {
        let target = try makeRenderTarget(width: base.width, height: base.height, pixelFormat: .rgba8Unorm)
        try encodePass(commandBuffer: commandBuffer, fragment: "look_glow", source: base, target: target)
        return target
    }

    /// Un pase de pantalla completa de `source` a `target` con el fragment shader `fragment`.
    private func encodePass(commandBuffer: MTLCommandBuffer, fragment: String, source: MTLTexture,
                            target: MTLTexture) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LookRendererError.resourceCreationFailed("render encoder")
        }
        var uniforms = LookUniforms.passThrough
        encoder.setRenderPipelineState(try pipeline(for: target.pixelFormat, fragment: fragment))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LookUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Escala/desplazamiento de las UV de la fuente para el modo de contenido pedido.
    public static func uvTransform(source: (Int, Int), destination: (Int, Int), contentMode: LookContentMode) -> SIMD4<Float> {
        guard contentMode != .stretch, source.0 > 0, source.1 > 0, destination.0 > 0, destination.1 > 0 else {
            return SIMD4(1, 1, 0, 0)
        }
        let sourceAspect = Float(source.0) / Float(source.1)
        let destinationAspect = Float(destination.0) / Float(destination.1)
        if contentMode == .aspectFit {
            // Coordenadas fuera de 0…1 = bandas negras (el shader las pinta).
            if sourceAspect > destinationAspect {
                let scale = sourceAspect / destinationAspect
                return SIMD4(1, scale, 0, (1 - scale) / 2)
            } else {
                let scale = destinationAspect / sourceAspect
                return SIMD4(scale, 1, (1 - scale) / 2, 0)
            }
        }
        if sourceAspect > destinationAspect {
            let scale = destinationAspect / sourceAspect
            return SIMD4(scale, 1, (1 - scale) / 2, 0)
        } else {
            let scale = sourceAspect / destinationAspect
            return SIMD4(1, scale, 0, (1 - scale) / 2)
        }
    }

    // MARK: - Imágenes completas

    /// Aplica el Look a una imagen completa (foto final). Trabaja en 8 bits en el espacio de color
    /// de la imagen (el LUT opera sobre valores codificados).
    public func render(image: CGImage, lut: MTLTexture?, parameters: LookParameters) throws -> CGImage {
        let (source, colorSpace) = try makeTexture(image: image)
        let target = try makeRenderTarget(width: image.width, height: image.height)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LookRendererError.resourceCreationFailed("command buffer")
        }
        try encode(commandBuffer: commandBuffer, source: source, lut: lut, destination: target, parameters: parameters)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try makeImage(texture: target, colorSpace: colorSpace)
    }

    /// La imagen como textura `.rgba8Unorm`, en su espacio de color (o sRGB si no es RGB).
    func makeTexture(image: CGImage) throws -> (MTLTexture, CGColorSpace) {
        let width = image.width, height = image.height
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace, bitmapInfo: Self.bitmapInfo)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LookRendererError.unsupportedImage }
        return (try makeTexture(rgba8: pixels, width: width, height: height), colorSpace)
    }

    /// Una textura `.rgba8Unorm` como `CGImage` en `colorSpace`.
    func makeImage(texture: MTLTexture, colorSpace: CGColorSpace) throws -> CGImage {
        let width = texture.width, height = texture.height
        let output = try readBytes(texture)
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw LookRendererError.unsupportedImage }
        return result
    }

    private static let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
}

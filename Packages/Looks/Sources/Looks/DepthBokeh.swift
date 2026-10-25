import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal

/// Mapa de profundidad de una foto, derecho como la foto. Guarda la disparidad (1 / distancia):
/// el desenfoque de una lente es proporcional a la diferencia de disparidad con el plano de foco.
public struct DepthMap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Disparidad por punto, por filas desde arriba a la izquierda. Con `isAbsolute`, en 1/m.
    public let disparity: [Float]
    /// Medida (con LiDAR): en 1/m de verdad. Si no, relativa: solo vale el orden (más cerca o más lejos).
    public let isAbsolute: Bool

    public init(width: Int, height: Int, disparity: [Float], isAbsolute: Bool) {
        precondition(disparity.count == width * height, "mapa de \(width)×\(height) con \(disparity.count) puntos")
        self.width = width
        self.height = height
        self.disparity = disparity
        self.isAbsolute = isAbsolute
    }

    /// El mapa de profundidad guardado dentro de una foto (HEIC/JPEG), derecho. nil si no tiene.
    public static func load(fromPhoto data: Data) -> DepthMap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                          ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth))
                as? [AnyHashable: Any],
              let depth = try? AVDepthData(fromDictionaryRepresentation: info)
        else { return nil }
        // El mapa está guardado como los píxeles de la foto (sin girar).
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return DepthMap(depthData: depth, orientation: CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// Un mapa de AVFoundation (de una foto o del visor en vivo), girado según `orientation`.
    public init?(depthData: AVDepthData, orientation: CGImagePropertyOrientation = .up) {
        var depth = depthData
        if orientation != .up {
            depth = depth.applyingExifOrientation(orientation)
        }
        if depth.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        }
        self.init(disparityBuffer: depth.depthDataMap, isAbsolute: depth.depthDataAccuracy == .absolute)
    }

    init?(disparityBuffer buffer: CVPixelBuffer, isAbsolute: Bool) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DisparityFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let v = row[x]
                values[y * width + x] = v.isFinite && v > 0 ? v : 0
            }
        }
        self.init(width: width, height: height, disparity: values, isAbsolute: isAbsolute)
    }

    /// Dónde enfocar y cómo leer la disparidad, para el shader.
    public struct Focus: Sendable, Equatable {
        /// Disparidad del plano nítido.
        public var disparity: Float
        /// Lleva una diferencia de disparidad a "1/m": 1 si el mapa es medido; si es relativo, lo
        /// estira para que el rango de la escena valga 1.
        public var scale: Float
        /// La persona está en foco: su recorte manda sobre la profundidad (bordes más limpios).
        public var personInFocus: Bool
    }

    /// El plano de foco: el punto tocado, o si no la persona, o si no el centro.
    public func focus(for bokeh: Bokeh, matte: PersonMatte?) -> Focus {
        let scale = isAbsolute ? 1 : relativeScale
        if let point = bokeh.focus {
            if let matte, matte.value(atX: point.x, y: point.y) >= 128, let d = median(inPersonOf: matte) {
                return Focus(disparity: d, scale: scale, personInFocus: true)
            }
            return Focus(disparity: median(aroundX: point.x, y: point.y, radius: 0.03), scale: scale,
                         personInFocus: false)
        }
        if let matte, let d = median(inPersonOf: matte) {
            return Focus(disparity: d, scale: scale, personInFocus: true)
        }
        return Focus(disparity: median(aroundX: 0.5, y: 0.5, radius: 0.1), scale: scale, personInFocus: false)
    }

    /// Mediana de la disparidad en una ventana cuadrada alrededor de un punto (coordenadas 0…1).
    func median(aroundX x: Float, y: Float, radius: Float) -> Float {
        let x0 = max(0, Int((x - radius) * Float(width))), x1 = min(width - 1, Int((x + radius) * Float(width)))
        let y0 = max(0, Int((y - radius) * Float(height))), y1 = min(height - 1, Int((y + radius) * Float(height)))
        var values: [Float] = []
        if x0 <= x1, y0 <= y1 {
            for row in y0...y1 {
                for column in x0...x1 where disparity[row * width + column] > 0 {
                    values.append(disparity[row * width + column])
                }
            }
        }
        return Self.median(values) ?? 0
    }

    /// Mediana de la disparidad sobre la persona.
    func median(inPersonOf matte: PersonMatte) -> Float? {
        var values: [Float] = []
        let step = max(1, Int((Double(width * height) / 20_000).squareRoot()))
        for row in stride(from: 0, to: height, by: step) {
            for column in stride(from: 0, to: width, by: step) {
                let d = disparity[row * width + column]
                guard d > 0 else { continue }
                let x = (Float(column) + 0.5) / Float(width), y = (Float(row) + 0.5) / Float(height)
                if matte.value(atX: x, y: y) >= 128 { values.append(d) }
            }
        }
        return Self.median(values)
    }

    /// Para un mapa relativo: el rango entre el 5 % más lejano y el 5 % más cercano vale 1.
    var relativeScale: Float {
        let step = max(1, disparity.count / 20_000)
        let values = stride(from: 0, to: disparity.count, by: step).map { disparity[$0] }.filter { $0 > 0 }.sorted()
        guard values.count > 10 else { return 1 }
        let low = values[values.count / 20], high = values[values.count * 19 / 20]
        return high > low ? 1 / (high - low) : 1
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

extension PersonMatte {
    /// Valor del recorte (0…255) en un punto 0…1 de la imagen derecha.
    func value(atX x: Float, y: Float) -> UInt8 {
        let column = min(width - 1, max(0, Int(x * Float(width))))
        let row = min(height - 1, max(0, Int(y * Float(height))))
        return pixels[row * width + column]
    }
}

/// Debe coincidir con `DepthUniforms` en BokehShaders.swift.
struct DepthUniforms {
    var workSize: SIMD2<Float>
    var maxRadius: Float
    var radiusPerDisparity: Float
    var focusDisparity: Float
    var blades: Float
    var roundness: Float
    var catEye: Float
    var highlightGain: Float
    var sampleCount: UInt32
    var hasMatte: UInt32
    var fullScale: Float
}

extension LookRenderer {
    /// Sube el mapa de profundidad como textura `.r32Float`.
    public func makeTexture(depth: DepthMap) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: depth.width, height: depth.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        let bytes = depth.disparity.withUnsafeBytes { Array($0) }
        return try upload(bytes, descriptor: descriptor, bytesPerPixel: 4)
    }

    /// Desenfoca la imagen (derecha) según la profundidad: cada punto, en proporción a su distancia al
    /// plano de foco, delante o detrás, como una lente de `focalLength` mm (ver
    /// `Bokeh.depthRadiusPerDiopter`). Con la persona en foco, su recorte afina los bordes.
    public func applyDepthBokeh(_ bokeh: Bokeh, to image: CGImage, depth: DepthMap, matte: PersonMatte?,
                                focalLength: Double = 24, lensFocalLength: Double = 24) throws -> CGImage {
        guard bokeh.isVisible(shortSide: min(image.width, image.height)) else { return image }
        let focus = depth.focus(for: bokeh, matte: matte)
        let (source, colorSpace) = try makeTexture(image: image)
        let target = try makeRenderTarget(width: image.width, height: image.height)
        let depthTexture = try makeTexture(depth: depth)
        let matteTexture = try matte.map { try makeTexture(matte: $0) }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LookRendererError.resourceCreationFailed("command buffer")
        }
        try encodeDepthBokeh(commandBuffer: commandBuffer, source: source, depth: depthTexture, matte: matteTexture,
                             focus: focus, destination: target, bokeh: bokeh, focalLength: focalLength,
                             lensFocalLength: lensFocalLength)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try makeImage(texture: target, colorSpace: colorSpace)
    }

    /// Codifica el bokeh por profundidad de `source` a `destination` (mismo tamaño, derechas como el
    /// mapa y el recorte): reduce la imagen, calcula el desenfoque de cada punto, lo reparte con la
    /// forma de la apertura y vuelve a poner nítido lo que está en foco.
    public func encodeDepthBokeh(commandBuffer: MTLCommandBuffer, source: MTLTexture, depth: MTLTexture,
                                 matte: MTLTexture?, focus: DepthMap.Focus, destination: MTLTexture, bokeh: Bokeh,
                                 focalLength: Double = 24, lensFocalLength: Double = 24,
                                 quality: BokehQuality = .photo, scratch: BokehScratch? = nil) throws {
        let radius = bokeh.depthRadiusPerDiopter(shortSide: min(source.width, source.height),
                                                 focalLength: focalLength, lensFocalLength: lensFocalLength)
        let maxRadius = max(radius * Bokeh.depthMaxDiopters, 1)
        let scale = Bokeh.depthWorkScale(radius: maxRadius, quality: quality)
        let workWidth = max(1, Int((Float(source.width) * scale).rounded()))
        let workHeight = max(1, Int((Float(source.height) * scale).rounded()))
        let prepared = try workTexture(scratch?.prepared, width: workWidth, height: workHeight, format: .rgba16Float)
        let coc = try workTexture(scratch?.coc, width: workWidth, height: workHeight, format: .r16Float)
        let blurred = try workTexture(scratch?.blurred, width: workWidth, height: workHeight, format: .rgba16Float)
        scratch?.prepared = prepared
        scratch?.coc = coc
        scratch?.blurred = blurred

        var uniforms = DepthUniforms(
            workSize: SIMD2(Float(workWidth), Float(workHeight)),
            maxRadius: maxRadius * scale,
            radiusPerDisparity: radius * scale * focus.scale,
            focusDisparity: focus.disparity,
            blades: Bokeh.blades,
            roundness: bokeh.roundness,
            catEye: Bokeh.catEye,
            highlightGain: Bokeh.highlightGain,
            sampleCount: quality.depthSampleCount,
            hasMatte: matte != nil && focus.personInFocus ? 1 : 0,
            fullScale: scale)

        try encodeDepthPass(commandBuffer: commandBuffer, fragment: "depth_prepare", textures: [source, depth],
                            target: prepared, uniforms: &uniforms)
        try encodeDepthPass(commandBuffer: commandBuffer, fragment: "depth_coc", textures: [depth, matte ?? depth, prepared],
                            target: coc, uniforms: &uniforms)
        try encodeDepthPass(commandBuffer: commandBuffer, fragment: "depth_gather", textures: [prepared, coc],
                            target: blurred, uniforms: &uniforms)
        try encodeDepthPass(commandBuffer: commandBuffer, fragment: "depth_composite",
                            textures: [source, blurred, coc, matte ?? coc, prepared],
                            target: destination, uniforms: &uniforms)
    }

    private func encodeDepthPass(commandBuffer: MTLCommandBuffer, fragment: String, textures: [MTLTexture],
                                 target: MTLTexture, uniforms: inout DepthUniforms) throws {
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
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DepthUniforms>.stride, index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

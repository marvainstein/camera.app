import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Looks

/// Imagen de prueba que recorre los 256 niveles de cada canal con combinaciones variadas.
private func testPattern(width: Int = 256, height: Int = 64) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x)
            pixels[i + 1] = UInt8((x * 7 + y * 13) % 256)
            pixels[i + 2] = UInt8((255 - x + y * 29) % 256)
        }
    }
    return pixels
}

private func render(_ renderer: LookRenderer, lut: LUT3D?, parameters: LookParameters,
                    pixels: [UInt8] = testPattern(), width: Int = 256, height: Int = 64,
                    format: MTLPixelFormat = .rgba8Unorm) throws -> [UInt8] {
    let source = try renderer.makeTexture(rgba8: pixels, width: width, height: height)
    let target = try renderer.makeRenderTarget(width: width, height: height, pixelFormat: format)
    let lutTexture = try lut.map { try renderer.makeLUTTexture($0) }
    let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
    try renderer.encode(commandBuffer: commandBuffer, source: source, lut: lutTexture,
                        destination: target, parameters: parameters)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return try renderer.readBytes(target)
}

private func maxChannelDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).enumerated()
        .filter { $0.offset % 4 != 3 }
        .map { abs(Int($0.element.0) - Int($0.element.1)) }
        .max() ?? 0
}

@Suite struct LUTFileTests {
    @Test func encodeDecodeRoundTrip() throws {
        let lut = LUT3D(size: 8) { SIMD3($0.z, $0.x, $0.y) }
        #expect(try LUT3D(data: lut.encoded()) == lut)
    }

    @Test func rejectsForeignFiles() {
        #expect(throws: LUT3D.Error.badHeader) { try LUT3D(data: Data("no es un LUT".utf8)) }
    }

    @Test func rejectsTruncatedFiles() throws {
        let data = LUT3D.identity(size: 4).encoded().dropLast(8)
        #expect(throws: LUT3D.Error.self) { try LUT3D(data: Data(data)) }
    }

    @Test func bundledLooksLoad() throws {
        let looks = try LookCatalog.bundled()
        #expect(looks.map(\.id) == ["identidad", "bn-neutro", "calido"])
        for look in looks {
            #expect(try LookCatalog.lut(for: look).size == 64)
        }
    }

    @Test func bundledIdentityMatchesGeneratedIdentity() throws {
        let identity = try #require(try LookCatalog.bundled().first { $0.id == "identidad" })
        #expect(try LookCatalog.lut(for: identity) == LUT3D.identity(size: 64))
    }
}

@Suite struct LookPipelineTests {
    let renderer: LookRenderer

    init() throws {
        renderer = try LookRenderer()
    }

    @Test func identityLUTLeavesImageUnchanged() throws {
        let input = testPattern()
        let output = try render(renderer, lut: .identity(), parameters: LookParameters(intensity: 1))
        #expect(maxChannelDifference(input, output) == 0)
    }

    @Test func identityLUTIsExactInHalfFloatTarget() throws {
        let input = testPattern()
        let target = try renderer.makeRenderTarget(width: 256, height: 64, pixelFormat: .rgba16Float)
        let source = try renderer.makeTexture(rgba8: input, width: 256, height: 64)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(commandBuffer: commandBuffer, source: source,
                            lut: renderer.makeLUTTexture(.identity()), destination: target,
                            parameters: LookParameters())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Leer como RGBA16F vía una copia a 8 bytes/píxel.
        let length = 256 * 64 * 8
        let buffer = try #require(renderer.device.makeBuffer(length: length, options: .storageModeShared))
        let readback = try #require(renderer.commandQueue.makeCommandBuffer())
        let blit = try #require(readback.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: 256, height: 64, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 256 * 8, destinationBytesPerImage: length)
        blit.endEncoding()
        readback.commit()
        readback.waitUntilCompleted()
        let bits = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self),
                                             count: 256 * 64 * 4))
        let floats = LUT3D.floats(fromHalfBits: bits)
        var worst: Float = 0
        for i in floats.indices where i % 4 != 3 {
            worst = max(worst, abs(floats[i] - Float(input[i]) / 255))
        }
        // Errores de float16 en el LUT + filtrado: muy por debajo de medio nivel de 8 bits.
        #expect(worst < 0.5 / 255)
    }

    @Test func zeroIntensityIgnoresLUT() throws {
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "bn-neutro" }))
        let output = try render(renderer, lut: bw, parameters: LookParameters(intensity: 0))
        #expect(maxChannelDifference(testPattern(), output) == 0)
    }

    @Test func noLUTPassesThrough() throws {
        let output = try render(renderer, lut: nil, parameters: LookParameters())
        #expect(maxChannelDifference(testPattern(), output) == 0)
    }

    @Test func bgraDestinationKeepsChannelOrder() throws {
        let output = try render(renderer, lut: .identity(), parameters: LookParameters(), format: .bgra8Unorm)
        let input = testPattern()
        // En memoria BGRA: el byte 0 es azul.
        #expect(output[0] == input[2] && output[1] == input[1] && output[2] == input[0])
    }

    @Test func blackAndWhiteLookIsNeutral() throws {
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "bn-neutro" }))
        let output = try render(renderer, lut: bw, parameters: LookParameters())
        for i in stride(from: 0, to: output.count, by: 4) {
            #expect(abs(Int(output[i]) - Int(output[i + 1])) <= 1)
            #expect(abs(Int(output[i + 1]) - Int(output[i + 2])) <= 1)
        }
    }

    @Test func gpuMatchesCPUReference() throws {
        let warm = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "calido" }))
        let input = testPattern()
        let output = try render(renderer, lut: warm, parameters: LookParameters(intensity: 0.75))
        let table = warm.floatTexels
        var worst = 0
        for i in stride(from: 0, to: input.count, by: 4) {
            let rgb = SIMD3(Float(input[i]), Float(input[i + 1]), Float(input[i + 2])) / 255
            let expected = rgb + (warm.apply(rgb, values: table) - rgb) * 0.75
            for c in 0..<3 {
                worst = max(worst, abs(Int((expected[c] * 255).rounded()) - Int(output[i + c])))
            }
        }
        #expect(worst <= 1)
    }

    @Test func grainIsDeterministicAndKeepsMeanBrightness() throws {
        let gray = [UInt8](repeating: 128, count: 256 * 64 * 4)
        let parameters = LookParameters(grain: 0.5, grainScale: 1, seed: 42)
        let a = try render(renderer, lut: nil, parameters: parameters, pixels: gray)
        let b = try render(renderer, lut: nil, parameters: parameters, pixels: gray)
        let c = try render(renderer, lut: nil, parameters: LookParameters(grain: 0.5, grainScale: 1, seed: 7), pixels: gray)
        #expect(a == b)
        #expect(a != c)
        #expect(maxChannelDifference(gray, a) > 0)

        let red = stride(from: 0, to: a.count, by: 4).map { Double(a[$0]) }
        let mean = red.reduce(0, +) / Double(red.count)
        let std = (red.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(red.count)).squareRoot()
        #expect(abs(mean - 128) < 1)
        // grain 0.5 → σ = 0.05 en medios tonos ≈ 12.75 niveles.
        #expect(abs(std - 12.75) < 2)
    }

    @Test func aspectFillCropsTheLongerSide() {
        let wide = LookRenderer.uvTransform(source: (1920, 1080), destination: (1080, 1080), contentMode: .aspectFill)
        #expect(abs(wide.x - 0.5625) < 1e-6 && wide.y == 1 && abs(wide.z - 0.21875) < 1e-6 && wide.w == 0)
        let tall = LookRenderer.uvTransform(source: (1080, 1920), destination: (1080, 1080), contentMode: .aspectFill)
        #expect(tall.x == 1 && abs(tall.y - 0.5625) < 1e-6)
    }

    @Test func rendersFullCGImage() throws {
        let pixels = testPattern()
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 256, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let lut = try renderer.makeLUTTexture(.identity())
        let output = try renderer.render(image: image, lut: lut, parameters: LookParameters())
        #expect(output.width == 256 && output.height == 64)
        let data = try #require(output.dataProvider?.data as Data?)
        #expect(maxChannelDifference(pixels, [UInt8](data)) == 0)
    }
}

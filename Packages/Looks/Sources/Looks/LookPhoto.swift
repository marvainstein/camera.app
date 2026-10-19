import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

extension LookRenderer {
    /// Decodifica una foto (HEIC/JPEG), le aplica el Look y la vuelve a codificar como HEIC,
    /// conservando los metadatos (EXIF, orientación, etc.).
    public func renderPhoto(_ data: Data, lut: MTLTexture?, parameters: LookParameters,
                            quality: Double = 0.9) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LookRendererError.unsupportedImage }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let rendered = try render(image: image, lut: lut, parameters: parameters)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil)
        else { throw LookRendererError.unsupportedImage }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LookRendererError.unsupportedImage }
        return output as Data
    }
}

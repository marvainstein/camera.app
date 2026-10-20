import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

extension LookRenderer {
    /// Textura para el visor a partir de una foto (HEIC/JPEG/PNG): derecha según su orientación,
    /// con `maxPixelSize` de lado largo como máximo y convertida a sRGB.
    public func makePreviewTexture(photo data: Data, maxPixelSize: Int = 2048) throws -> MTLTexture {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw LookRendererError.unsupportedImage }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB, bitmapInfo: bitmapInfo)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LookRendererError.unsupportedImage }
        return try makeTexture(rgba8: pixels, width: width, height: height)
    }

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

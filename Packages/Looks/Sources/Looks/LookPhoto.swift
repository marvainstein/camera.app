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

    /// Decodifica una foto (HEIC/JPEG), le aplica el Look y la vuelve a codificar (HEIC o JPEG según
    /// `outputType`), conservando los metadatos (EXIF, orientación, etc.).
    ///
    /// Con `framing` la foto se recorta al marco antes de aplicar el Look (así el viñeteo y el grano
    /// se miden sobre el recorte); `lensFocalLength` es la focal equivalente del lente que la sacó.
    ///
    /// Con `bokeh`, antes de todo se desenfoca lo que no es una persona (la óptica va antes que la
    /// película). Si no hay una persona, la foto queda nítida.
    public func renderPhoto(_ data: Data, lut: MTLTexture?, parameters: LookParameters,
                            framing: Framing = Framing(), lensFocalLength: Double = 24, bokeh: Bokeh? = nil,
                            outputType: UTType = .heic, quality: Double = 0.9) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LookRendererError.unsupportedImage }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        if let bokeh, bokeh.radius(shortSide: min(image.width, image.height)) >= Bokeh.minimumRadius,
           let matte = PersonMatte.detect(inPhoto: data) {
            image = try applyBokeh(bokeh, to: image, matte: matte, orientation: orientation)
        }

        if !framing.isFullFrame {
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let shown = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            let r = Framing.storedRect(framing.rect(in: shown, lensFocalLength: lensFocalLength), orientation: orientation)
            let pixels = CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if let cropped = image.cropping(to: pixels) {
                image = cropped
                // Las dimensiones guardadas en los metadatos ya no valen: que las escriba el destino.
                properties[kCGImagePropertyPixelWidth] = nil
                properties[kCGImagePropertyPixelHeight] = nil
                if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                    exif[kCGImagePropertyExifPixelXDimension] = nil
                    exif[kCGImagePropertyExifPixelYDimension] = nil
                    properties[kCGImagePropertyExifDictionary] = exif
                }
            }
        }

        let rendered = try render(image: image, lut: lut, parameters: parameters)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil)
        else { throw LookRendererError.unsupportedImage }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LookRendererError.unsupportedImage }
        return output as Data
    }
}

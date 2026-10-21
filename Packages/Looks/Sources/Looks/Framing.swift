import CoreGraphics
import Foundation
import ImageIO

/// Encuadre por recorte, como el modo crop de las compactas: una focal más larga que la del lente
/// (recorte al centro) y un formato. El visor muestra el cuadro entero con el marco del recorte;
/// la foto se guarda recortada.
public struct Framing: Sendable, Hashable, Codable {
    public enum Aspect: String, Sendable, CaseIterable, Identifiable, Codable {
        /// El del sensor, sin recortar los lados.
        case native = "4:3"
        case threeTwo = "3:2"
        case square = "1:1"
        case sixteenNine = "16:9"

        public var id: String { rawValue }

        /// Lado largo / lado corto.
        var ratio: Double {
            switch self {
            case .native: 4.0 / 3.0
            case .threeTwo: 3.0 / 2.0
            case .square: 1
            case .sixteenNine: 16.0 / 9.0
            }
        }
    }

    /// Focal equivalente en 35 mm; nil = la del lente.
    public var focalLength: Double?
    public var aspect: Aspect

    /// Focales que ofrece la UI.
    public static let focalLengths: [Double] = [28, 35, 50, 75]

    public init(focalLength: Double? = nil, aspect: Aspect = .native) {
        self.focalLength = focalLength
        self.aspect = aspect
    }

    public var isFullFrame: Bool { focalLength == nil && aspect == .native }

    /// Rectángulo del recorte en coordenadas normalizadas (0…1, origen arriba a la izquierda) de una
    /// imagen de `size` ya derecha (vertical u horizontal), con el lente de `lensFocalLength`.
    /// El formato sigue la orientación de la imagen: 3:2 en una foto vertical es 2:3.
    public func rect(in size: CGSize, lensFocalLength: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let portrait = size.height > size.width
        let target = portrait ? 1 / aspect.ratio : aspect.ratio
        let source = Double(size.width / size.height)
        // El rectángulo más grande del formato que entra en la imagen…
        var width = 1.0, height = 1.0
        if target > source {
            height = source / target
        } else {
            width = target / source
        }
        // …achicado por la relación entre focales (nunca más ancho que el lente).
        let zoom = max(1, (focalLength ?? lensFocalLength) / lensFocalLength)
        width /= zoom
        height /= zoom
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// Focal equivalente en 35 mm que dice el EXIF de una foto, si la tiene.
    public static func lensFocalLength(ofPhoto data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, focal > 0
        else { return nil }
        return focal
    }

    /// El mismo rectángulo, pasado a las coordenadas de la imagen tal como está guardada (sin rotar)
    /// según su orientación EXIF (1 normal, 3 girada 180°, 6 y 8 giradas 90°). Las orientaciones
    /// espejadas no salen de la cámara trasera: se tratan como su versión sin espejo.
    public static func storedRect(_ r: CGRect, orientation: Int) -> CGRect {
        switch orientation {
        case 3, 4: CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        case 6, 5: CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case 8, 7: CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        default: r
        }
    }
}

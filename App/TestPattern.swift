import Foundation

/// Patrón de prueba propio para ver los Looks sin cámara (simulador): arriba un barrido de tono
/// con brillo variable, abajo una rampa de grises y parches de color.
enum TestPattern {
    static func rgba8(width: Int = 1080, height: Int = 1920) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let patches: [(Float, Float, Float)] = [
            (0.45, 0.32, 0.26), (0.76, 0.58, 0.50), (0.36, 0.48, 0.61), (0.35, 0.42, 0.26),
            (0.85, 0.47, 0.15), (0.20, 0.25, 0.55), (0.75, 0.32, 0.38), (0.55, 0.70, 0.25),
        ]
        for y in 0..<height {
            let v = Float(y) / Float(height)
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                let rgb: (Float, Float, Float)
                if v < 0.6 {
                    rgb = hsv(hue: u, saturation: 0.85, value: 1 - v / 0.6 * 0.9)
                } else if v < 0.75 {
                    rgb = (u, u, u)
                } else {
                    rgb = patches[min(Int(u * 4), 3) + (v < 0.875 ? 0 : 4)]
                }
                let i = (y * width + x) * 4
                pixels[i] = UInt8(rgb.0 * 255)
                pixels[i + 1] = UInt8(rgb.1 * 255)
                pixels[i + 2] = UInt8(rgb.2 * 255)
            }
        }
        return pixels
    }

    private static func hsv(hue: Float, saturation s: Float, value v: Float) -> (Float, Float, Float) {
        let h = hue * 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(h) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

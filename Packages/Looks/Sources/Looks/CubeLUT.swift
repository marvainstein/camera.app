import Foundation

extension LUT3D {
    public enum CubeError: Swift.Error, Equatable {
        /// Falta `LUT_3D_SIZE`: no es un LUT 3D.
        case notA3DLUT
        /// Tiene un LUT o shaper 1D (todavía no soportado).
        case has1DLUT
        case wrongRowCount(expected: Int, actual: Int)
        /// Una fila de datos que no son tres números (línea, desde 1).
        case badRow(Int)
    }

    /// Lee un LUT 3D `.cube` (Resolve/Adobe, cualquier tamaño, con o sin `DOMAIN_MIN/MAX`) y lo
    /// remuestrea a `size`³ con interpolación trilineal. El `.cube` tiene que esperar valores sRGB,
    /// como los que le da la app. Igual que `read_cube`/`cube_sampler` de `scripts/make_luts.py`.
    public init(cube text: String, size: Int = 64) throws {
        var n: Int?
        var data = [SIMD3<Float>]()
        var domainMin = SIMD3<Float>(0, 0, 0), domainMax = SIMD3<Float>(1, 1, 1)
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let first = parts.first else { continue }
            let numbers = parts.dropFirst().prefix(3).compactMap { Float(String($0)) }
            switch first.uppercased() {
            case "LUT_3D_SIZE":
                n = parts.count > 1 ? Int(String(parts[1])) : nil
            case "DOMAIN_MIN" where numbers.count == 3:
                domainMin = SIMD3(numbers[0], numbers[1], numbers[2])
            case "DOMAIN_MAX" where numbers.count == 3:
                domainMax = SIMD3(numbers[0], numbers[1], numbers[2])
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                throw CubeError.has1DLUT
            default:
                if first.first?.isLetter == true || first.first == "_" { continue }  // TITLE, etc.
                let values = parts.prefix(3).compactMap { Float(String($0)) }
                guard values.count == 3 else { throw CubeError.badRow(index + 1) }
                data.append(SIMD3(values[0], values[1], values[2]))
            }
        }
        guard let n, n >= 2 else { throw CubeError.notA3DLUT }
        guard data.count == n * n * n else { throw CubeError.wrongRowCount(expected: n * n * n, actual: data.count) }

        let span = domainMax - domainMin
        let maxIndex = Float(n - 2)
        self.init(size: size) { rgb in
            let normalized: SIMD3<Float> = (rgb - domainMin) / span
            let p: SIMD3<Float> = normalized.clamped(lowerBound: .zero, upperBound: .one) * Float(n - 1)
            let r0 = Int(min(p.x, maxIndex)), g0 = Int(min(p.y, maxIndex)), b0 = Int(min(p.z, maxIndex))
            let t: SIMD3<Float> = p - SIMD3<Float>(Float(r0), Float(g0), Float(b0))
            var out = SIMD3<Float>.zero
            for corner in 0..<8 {
                let dr: Int = corner & 1
                let dg: Int = (corner >> 1) & 1
                let db: Int = (corner >> 2) & 1
                let wr: Float = dr == 1 ? t.x : 1 - t.x
                let wg: Float = dg == 1 ? t.y : 1 - t.y
                let wb: Float = db == 1 ? t.z : 1 - t.z
                let index: Int = (r0 + dr) + (g0 + dg) * n + (b0 + db) * n * n
                out += (wr * wg * wb) * data[index]
            }
            return out.clamped(lowerBound: .zero, upperBound: .one)
        }
    }
}

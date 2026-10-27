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
        try self.init(cubeData: Data(text.utf8), size: size)
    }

    /// Como `init(cube:size:)`, leyendo los bytes del archivo. Los números se leen directo de los bytes
    /// (un `.cube` de 64³ tiene más de 780 mil): armar un `String` por número era lo más lento.
    public init(cubeData: Data, size: Int = 64) throws {
        var n: Int?
        var data = [SIMD3<Float>]()
        var domainMin = SIMD3<Float>(0, 0, 0), domainMax = SIMD3<Float>(1, 1, 1)
        var bytes = [UInt8](cubeData)
        bytes.append(0)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let end = buffer.count - 1
            var lineStart = 0
            var lineNumber = 0
            while lineStart < end {
                lineNumber += 1
                var lineEnd = lineStart
                while lineEnd < end, base[lineEnd] != 0x0A, base[lineEnd] != 0x0D { lineEnd += 1 }
                // "\r\n" cuenta como un solo salto de línea.
                var next = lineEnd + 1
                if lineEnd < end, base[lineEnd] == 0x0D, base[lineEnd + 1] == 0x0A { next += 1 }
                defer { lineStart = next }
                // Hasta el comentario, sin los espacios del principio.
                var contentEnd = lineStart
                while contentEnd < lineEnd, base[contentEnd] != 0x23 { contentEnd += 1 }
                var p = lineStart
                while p < contentEnd, base[p] == 0x20 || base[p] == 0x09 { p += 1 }
                guard p < contentEnd else { continue }
                let first = base[p]
                let isWord = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) || first == 0x5F
                if isWord {
                    // Palabras clave (pocas líneas): como texto.
                    let line = String(decoding: UnsafeBufferPointer(start: base + p, count: contentEnd - p), as: UTF8.self)
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    let numbers = parts.dropFirst().prefix(3).compactMap { Float(String($0)) }
                    switch parts.first?.uppercased() {
                    case "LUT_3D_SIZE":
                        n = parts.count > 1 ? Int(String(parts[1])) : nil
                        if let n, n >= 2 { data.reserveCapacity(n * n * n) }
                    case "DOMAIN_MIN" where numbers.count == 3:
                        domainMin = SIMD3(numbers[0], numbers[1], numbers[2])
                    case "DOMAIN_MAX" where numbers.count == 3:
                        domainMax = SIMD3(numbers[0], numbers[1], numbers[2])
                    case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                        throw CubeError.has1DLUT
                    default:
                        continue  // TITLE, etc.
                    }
                    continue
                }
                // Tres números: se termina la línea con un 0 (el buffer es una copia) y se leen con strtof.
                let saved = base[contentEnd]
                base[contentEnd] = 0
                defer { base[contentEnd] = saved }
                var values = SIMD3<Float>()
                var cursor = UnsafeMutablePointer<CChar>(OpaquePointer(base + p))
                for component in 0..<3 {
                    var after: UnsafeMutablePointer<CChar>?
                    let value = strtof(cursor, &after)
                    guard let after, after != cursor else { throw CubeError.badRow(lineNumber) }
                    values[component] = value
                    cursor = after
                }
                data.append(values)
            }
        }
        guard let n, n >= 2 else { throw CubeError.notA3DLUT }
        guard data.count == n * n * n else { throw CubeError.wrongRowCount(expected: n * n * n, actual: data.count) }

        // Del mismo tamaño y sin dominio: los valores tal cual (remuestrear daría lo mismo, más lento).
        if n == size, domainMin == .zero, domainMax == .one {
            var floats = [Float]()
            floats.reserveCapacity(n * n * n * 4)
            for value in data {
                let clamped = value.clamped(lowerBound: .zero, upperBound: .one)
                floats += [clamped.x, clamped.y, clamped.z, 1]
            }
            try self.init(size: size, texels: LUT3D.halfBits(from: floats))
            return
        }

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

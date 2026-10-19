import Accelerate
import Foundation

/// LUT 3D cúbico de N³ texeles RGBA en float16 (bits crudos), R variando más rápido.
///
/// Es el mismo layout que una textura Metal 3D `.rgba16Float`, así que se sube sin reordenar.
/// Se guardan los bits en `UInt16` porque `Float16` no existe en macOS x86_64.
public struct LUT3D: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable {
        case badHeader
        case unsupportedVersion(UInt32)
        case sizeMismatch(expected: Int, actual: Int)
    }

    static let magic = Array("LAIKALUT".utf8)
    static let version: UInt32 = 1
    static let headerLength = 16

    public let size: Int
    /// `size³ × 4` valores float16 (bits) en orden R→G→B, canales RGBA.
    public let texels: [UInt16]

    public init(size: Int, texels: [UInt16]) throws {
        guard texels.count == size * size * size * 4 else {
            throw Error.sizeMismatch(expected: size * size * size * 4, actual: texels.count)
        }
        self.size = size
        self.texels = texels
    }

    /// Construye un LUT evaluando `transform` en cada nodo de la grilla (valores en 0…1).
    public init(size: Int = 64, transform: (SIMD3<Float>) -> SIMD3<Float>) {
        var floats = [Float]()
        floats.reserveCapacity(size * size * size * 4)
        let step = 1 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(SIMD3(Float(r), Float(g), Float(b)) * step)
                    floats += [out.x, out.y, out.z, 1]
                }
            }
        }
        self.size = size
        self.texels = LUT3D.halfBits(from: floats)
    }

    public static func identity(size: Int = 64) -> LUT3D {
        LUT3D(size: size) { $0 }
    }

    /// Lee el formato binario propio que genera `scripts/make_luts.py`.
    public init(data: Data) throws {
        let bytes = [UInt8](data.prefix(Self.headerLength))
        guard bytes.count >= Self.headerLength, Array(bytes[0..<8]) == Self.magic else {
            throw Error.badHeader
        }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let version = u32(8)
        guard version == Self.version else { throw Error.unsupportedVersion(version) }
        let size = Int(u32(12))
        // Todas las plataformas Apple son little-endian: se copian los bits tal cual.
        let payload = data.dropFirst(Self.headerLength)
        var texels = [UInt16](repeating: 0, count: payload.count / 2)
        texels.withUnsafeMutableBytes { _ = payload.copyBytes(to: $0) }
        try self.init(size: size, texels: texels)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func encoded() -> Data {
        var data = Data(Self.magic)
        for value in [Self.version, UInt32(size)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        texels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Valores RGBA como `Float`.
    public var floatTexels: [Float] {
        Self.floats(fromHalfBits: texels)
    }

    /// Referencia en CPU (interpolación trilineal) para validar el kernel de GPU.
    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let values = floatTexels
        return apply(rgb, values: values)
    }

    func apply(_ rgb: SIMD3<Float>, values: [Float]) -> SIMD3<Float> {
        let n = size
        let maxIndex = Float(n - 2)
        let p = rgb.clamped(lowerBound: .zero, upperBound: .one) * Float(n - 1)
        let r0 = Int(min(p.x, maxIndex)), g0 = Int(min(p.y, maxIndex)), b0 = Int(min(p.z, maxIndex))
        let t = p - SIMD3<Float>(Float(r0), Float(g0), Float(b0))
        var out = SIMD3<Float>.zero
        for corner in 0..<8 {
            let dr = corner & 1, dg = (corner >> 1) & 1, db = (corner >> 2) & 1
            let wr: Float = dr == 1 ? t.x : 1 - t.x
            let wg: Float = dg == 1 ? t.y : 1 - t.y
            let wb: Float = db == 1 ? t.z : 1 - t.z
            let node: Int = (r0 + dr) + (g0 + dg) * n + (b0 + db) * n * n
            let index = node * 4
            out += (wr * wg * wb) * SIMD3<Float>(values[index], values[index + 1], values[index + 2])
        }
        return out
    }

    static func floats(fromHalfBits bits: [UInt16]) -> [Float] {
        var src = bits
        var dst = [Float](repeating: 0, count: bits.count)
        src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: 1, width: vImagePixelCount(bits.count), rowBytes: s.count)
                var db = vImage_Buffer(data: d.baseAddress, height: 1, width: vImagePixelCount(bits.count), rowBytes: d.count)
                _ = vImageConvert_Planar16FtoPlanarF(&sb, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        return dst
    }

    static func halfBits(from floats: [Float]) -> [UInt16] {
        var src = floats
        var dst = [UInt16](repeating: 0, count: floats.count)
        src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: 1, width: vImagePixelCount(floats.count), rowBytes: s.count)
                var db = vImage_Buffer(data: d.baseAddress, height: 1, width: vImagePixelCount(floats.count), rowBytes: d.count)
                _ = vImageConvert_PlanarFtoPlanar16F(&sb, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        return dst
    }
}

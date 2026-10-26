import Compression
import Foundation

/// Lector mínimo de archivos `.zip` (sin dependencias): lista las entradas y descomprime las que vienen
/// sin comprimir o con deflate, que es lo que generan la Mac, Windows y casi todo. Sirve para importar
/// varios `.cube` de una.
public enum ZipArchive {
    public enum Error: Swift.Error, Equatable {
        case notAZip
        case unsupportedCompression(String)
        case corrupt(String)
    }

    public struct Entry: Sendable, Equatable {
        /// Ruta dentro del `.zip` (con carpetas).
        public let path: String
        public let data: Data

        /// El nombre del archivo, sin carpetas ni extensión.
        public var name: String { ZipArchive.name(of: path) }
    }

    /// Un archivo del `.zip`, todavía sin descomprimir.
    public struct File: Sendable, Equatable {
        public let path: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int

        /// El nombre del archivo, sin carpetas ni extensión.
        public var name: String { ZipArchive.name(of: path) }
    }

    static func name(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Los archivos (no carpetas) que `include` acepta por su ruta, leyendo solo el índice. Ignora lo
    /// que agrega la Mac al comprimir (`__MACOSX/`, `._archivo`).
    public static func files(in data: Data, include: (String) -> Bool = { _ in true }) throws -> [File] {
        guard let end = endOfCentralDirectory(in: data) else { throw Error.notAZip }
        let count = Int(read16(data, end + 10))
        var offset = Int(read32(data, end + 16))
        var files: [File] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x0201_4B50 else { throw Error.corrupt("índice") }
            let nameLength = Int(read16(data, offset + 28))
            guard offset + 46 + nameLength <= data.count else { throw Error.corrupt("nombre") }
            let start = data.startIndex + offset + 46
            let path = String(decoding: data[start..<(start + nameLength)], as: UTF8.self)
            let file = File(path: path, method: read16(data, offset + 10),
                            compressedSize: Int(read32(data, offset + 20)), size: Int(read32(data, offset + 24)),
                            localOffset: Int(read32(data, offset + 42)))
            offset += 46 + nameLength + Int(read16(data, offset + 30)) + Int(read16(data, offset + 32))
            let fileName = (path as NSString).lastPathComponent
            guard !path.hasSuffix("/"), !path.hasPrefix("__MACOSX/"), !fileName.hasPrefix("._"), include(path)
            else { continue }
            files.append(file)
        }
        return files
    }

    /// El contenido de un archivo de `files(in:)`, descomprimido.
    public static func extract(_ file: File, from data: Data) throws -> Data {
        let local = file.localOffset
        guard local + 30 <= data.count, read32(data, local) == 0x0403_4B50 else { throw Error.corrupt(file.path) }
        let start = local + 30 + Int(read16(data, local + 26)) + Int(read16(data, local + 28))
        guard start + file.compressedSize <= data.count else { throw Error.corrupt(file.path) }
        let stored = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + file.compressedSize))
        switch file.method {
        case 0: return stored
        case 8: return try inflate(stored, size: file.size, path: file.path)
        default: throw Error.unsupportedCompression(file.path)
        }
    }

    /// Todos los archivos que `include` acepta, descomprimidos (para pocos o chicos; si no, `files` y
    /// `extract` de a uno).
    public static func entries(in data: Data, include: (String) -> Bool = { _ in true }) throws -> [Entry] {
        try files(in: data, include: include).map { Entry(path: $0.path, data: try extract($0, from: data)) }
    }

    /// "Deflate" crudo, como lo guarda el `.zip` (`COMPRESSION_ZLIB` es exactamente eso).
    private static func inflate(_ data: Data, size: Int, path: String) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Error.corrupt(path) }
        return output
    }

    /// El final del índice está al final del archivo, antes de un comentario de hasta 64 KB.
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        for offset in stride(from: data.count - 22, through: lowest, by: -1) where read32(data, offset) == 0x0605_4B50 {
            return offset
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(read16(data, offset)) | UInt32(read16(data, offset + 2)) << 16
    }
}

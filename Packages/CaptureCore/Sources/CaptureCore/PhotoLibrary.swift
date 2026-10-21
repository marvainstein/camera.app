#if os(iOS)
import Foundation
import Photos

/// Guardado en Fotos. Con RAW + JPG/HEIC quedan dos fotos separadas: la procesada (con el Look) y
/// el DNG intacto, cada una visible y exportable por su lado.
///
/// La procesada se guarda **editable**: primero el original y, encima, una edición de Fotos con la
/// versión con el Look y los ajustes de la app (`PHAdjustmentData`). Así se puede reabrir desde la app
/// y cambiar todo partiendo del original, y "Revertir" en Fotos vuelve a la foto sin tocar.
public enum PhotoLibrary {
    /// Ajustes que entiende la app: su identificador y versión de formato.
    public struct AdjustmentFormat: Sendable {
        public let identifier: String
        public let version: String

        public init(identifier: String, version: String) {
            self.identifier = identifier
            self.version = version
        }
    }

    /// Una foto de la fototeca abierta para editarla sin perder el original.
    public struct EditablePhoto: @unchecked Sendable {
        public let localIdentifier: String
        /// Lo que hay que re-renderizar: el original si la última edición fue de esta app; si no, la
        /// foto como se ve ahora.
        public let original: Data
        /// Los ajustes que guardó esta app la última vez, si la editó ella.
        public let adjustment: Data?
        let asset: PHAsset
        let input: PHContentEditingInput
    }

    /// Guarda sin edición (solo agregar a Fotos).
    public static func save(processed: Data?, raw: Data?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            for data in [processed, raw].compactMap({ $0 }) {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        }
    }

    /// Guarda una toma editable: el original y, encima, `rendered` (JPEG) con `adjustment`. Sin
    /// permiso de lectura de la fototeca, o si la edición falla, queda guardada como antes (solo
    /// `rendered`, sin original).
    public static func saveEditable(original: Data, rendered: Data, adjustment: Data, format: AdjustmentFormat,
                                    raw: Data?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            try await save(processed: rendered, raw: raw)
            return
        }
        let created = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: original, options: nil)
            created.value = request.placeholderForCreatedAsset?.localIdentifier
            if let raw {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: raw, options: nil)
            }
        }
        do {
            guard let identifier = created.value,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            else { throw CameraError.captureFailed("no se encontró la foto recién guardada") }
            let input = try await contentEditingInput(for: asset, format: format)
            try await apply(rendered: rendered, adjustment: adjustment, format: format, to: asset, input: input)
        } catch {
            // El original ya está en Fotos; si no se pudo editar, se agrega la versión con el Look aparte
            // para no perderla.
            try await save(processed: rendered, raw: nil)
        }
    }

    /// Abre una foto de la fototeca para editarla (pide acceso completo a Fotos).
    public static func openForEditing(localIdentifier: String, format: AdjustmentFormat) async throws -> EditablePhoto {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw CameraError.captureFailed("no se encontró la foto")
        }
        let input = try await contentEditingInput(for: asset, format: format)
        guard let url = input.fullSizeImageURL else { throw CameraError.captureFailed("la foto no tiene imagen") }
        let original = try Data(contentsOf: url)
        let ours = input.adjustmentData.flatMap {
            $0.formatIdentifier == format.identifier && $0.formatVersion == format.version ? $0.data : nil
        }
        return EditablePhoto(localIdentifier: localIdentifier, original: original, adjustment: ours, asset: asset,
                             input: input)
    }

    /// Reemplaza la edición de la foto: `rendered` (JPEG) con `adjustment`. El original no se toca.
    public static func saveEdit(of photo: EditablePhoto, rendered: Data, adjustment: Data,
                                format: AdjustmentFormat) async throws {
        try await apply(rendered: rendered, adjustment: adjustment, format: format, to: photo.asset, input: photo.input)
    }

    // MARK: - Privado

    /// El identificador del asset creado dentro de `performChanges` (que corre en otra cola).
    private final class IdentifierBox: @unchecked Sendable {
        var value: String?
    }

    /// Objetos de Photos que no son `Sendable` y tienen que cruzar a la cola de `performChanges`.
    private struct EditBox: @unchecked Sendable {
        let asset: PHAsset
        let output: PHContentEditingOutput
    }

    private struct InputBox: @unchecked Sendable {
        let input: PHContentEditingInput
    }

    private static func contentEditingInput(for asset: PHAsset, format: AdjustmentFormat) async throws
        -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Si la última edición es nuestra, Fotos nos da el original y nuestros ajustes.
        let identifier = format.identifier, version = format.version
        options.canHandleAdjustmentData = { $0.formatIdentifier == identifier && $0.formatVersion == version }
        let box: InputBox = try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input {
                    continuation.resume(returning: InputBox(input: input))
                } else {
                    continuation.resume(throwing: CameraError.captureFailed("no se pudo abrir la foto para editarla"))
                }
            }
        }
        return box.input
    }

    private static func apply(rendered: Data, adjustment: Data, format: AdjustmentFormat, to asset: PHAsset,
                              input: PHContentEditingInput) async throws {
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: format.identifier, formatVersion: format.version,
                                                 data: adjustment)
        try rendered.write(to: output.renderedContentURL, options: .atomic)
        let box = EditBox(asset: asset, output: output)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: box.asset).contentEditingOutput = box.output
        }
    }
}
#endif

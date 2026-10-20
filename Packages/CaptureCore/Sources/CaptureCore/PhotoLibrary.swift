#if os(iOS)
import Foundation
import Photos

/// Guardado en Fotos. Con ProRAW el HEIC queda como foto principal y el DNG como alternativa
/// (igual que un par RAW+JPEG); si solo hay DNG, el DNG es la foto.
public enum PhotoLibrary {
    public static func save(processed: Data?, raw: Data?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let processed {
                request.addResource(with: .photo, data: processed, options: nil)
                if let raw { request.addResource(with: .alternatePhoto, data: raw, options: nil) }
            } else if let raw {
                request.addResource(with: .photo, data: raw, options: nil)
            }
        }
    }
}
#endif

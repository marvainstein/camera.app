#if os(iOS)
import Foundation
import Photos

/// Guardado en Fotos. Con RAW + JPG/HEIC quedan dos fotos separadas: la procesada (con el Look) y
/// el DNG intacto, cada una visible y exportable por su lado.
public enum PhotoLibrary {
    public static func save(processed: Data?, raw: Data?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CameraError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            for data in [processed, raw].compactMap({ $0 }) {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        }
    }
}
#endif

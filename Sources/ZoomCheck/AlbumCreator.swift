import Foundation
import Photos

enum AlbumError: LocalizedError {
    case notAuthorized
    case noAssetsFound

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "ZoomCheck has no access to Photos. Allow it in System Settings → Privacy & Security → Photos."
        case .noAssetsFound:
            return "None of the photos could be found through PhotoKit."
        }
    }
}

enum AlbumCreator {
    /// Creates a regular album in Photos; it syncs to other devices via iCloud.
    static func createAlbum(named name: String, uuids: [String]) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw AlbumError.notAuthorized }

        // On macOS a PhotoKit local identifier is "<ZUUID>/L0/001".
        let identifiers = uuids.map { "\($0)/L0/001" }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { throw AlbumError.noAssetsFound }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            request.addAssets(assets)
        }
        return assets.count
    }
}

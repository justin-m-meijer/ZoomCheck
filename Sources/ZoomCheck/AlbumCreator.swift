import Foundation
import Photos

enum AlbumError: LocalizedError {
    case notAuthorized
    case noAssetsFound
    case nothingAdded(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "ZoomCheck has no access to Photos. Allow it in System Settings → Privacy & Security → Photos."
        case .noAssetsFound:
            return "None of the photos could be found in Photos."
        case .nothingAdded(let detail):
            return "Photos refused to add the photos to an album. \(detail)"
        }
    }
}

struct AlbumOutcome {
    let name: String
    let added: Int
    let skipped: Int
}

/// Reference box so a change block can hand a value back without capturing a mutable variable.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

enum AlbumCreator {
    private static let batchSize = 200

    /// Adds the photos to a regular album (reusing one with the same name), which syncs via iCloud.
    ///
    /// PhotoKit rejects a whole change with PHPhotosErrorDomain 3300 ("change not supported") when a
    /// single asset can't go into an album, e.g. photos from an iCloud shared album. So photos are added
    /// in batches, failing batches are split until the offending photos are isolated, and anything
    /// PhotoKit still refuses is retried through Photos' AppleScript interface.
    static func addToAlbum(named name: String, uuids: [String]) async throws -> AlbumOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw AlbumError.notAuthorized }

        // On macOS a PhotoKit local identifier is "<ZUUID>/L0/001".
        let identifiers = uuids.map { "\($0)/L0/001" }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetch.count > 0 else { throw AlbumError.noAssetsFound }

        var assets: [PHAsset] = []
        var notInLibrary = uuids.count - fetch.count
        fetch.enumerateObjects { asset, _, _ in
            // Photos from iCloud shared albums can't be added to your own albums.
            if asset.sourceType.contains(.typeUserLibrary) {
                assets.append(asset)
            } else {
                notInLibrary += 1
            }
        }

        var added = 0
        var failed: [PHAsset] = []
        var photoKitError: Error?

        do {
            let album = try await findOrCreateAlbum(named: name)
            var start = 0
            while start < assets.count {
                let batch = Array(assets[start..<min(start + batchSize, assets.count)])
                let result = await add(batch, to: album)
                added += result.added
                failed += result.failed
                photoKitError = photoKitError ?? result.error
                start += batchSize
            }
        } catch {
            // Creating the album itself failed; let AppleScript try everything.
            photoKitError = error
            failed = assets
        }

        if !failed.isEmpty {
            let failedUUIDs = failed.map { $0.localIdentifier.components(separatedBy: "/").first ?? $0.localIdentifier }
            if let viaScript = try? await addWithAppleScript(albumName: name, uuids: failedUUIDs) {
                added += viaScript
                failed.removeFirst(min(viaScript, failed.count))
            }
        }

        if added == 0 {
            let detail = photoKitError.map(describe) ?? "No photos were accepted."
            throw AlbumError.nothingAdded(detail)
        }
        return AlbumOutcome(name: name, added: added, skipped: failed.count + notInLibrary)
    }

    // MARK: - PhotoKit

    private static func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            return existing
        }

        let placeholder = Box<String>()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = placeholder.value,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else {
            throw AlbumError.nothingAdded("The album could not be created.")
        }
        return album
    }

    private static func add(_ assets: [PHAsset], to album: PHAssetCollection) async -> (added: Int, failed: [PHAsset], error: Error?) {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
            }
            return (assets.count, [], nil)
        } catch {
            guard assets.count > 1 else { return (0, assets, error) }
            let middle = assets.count / 2
            let left = await add(Array(assets[..<middle]), to: album)
            let right = await add(Array(assets[middle...]), to: album)
            return (left.added + right.added, left.failed + right.failed, left.error ?? right.error ?? error)
        }
    }

    // MARK: - AppleScript fallback

    /// Returns how many photos Photos accepted.
    private static func addWithAppleScript(albumName: String, uuids: [String]) async throws -> Int {
        let ids = uuids.map { "\"\(escape($0))/L0/001\"" }.joined(separator: ", ")
        let script = """
            tell application "Photos"
                set albumName to "\(escape(albumName))"
                if exists album albumName then
                    set theAlbum to album albumName
                else
                    set theAlbum to make new album named albumName
                end if
                set addedCount to 0
                repeat with theID in {\(ids)}
                    try
                        add {media item id (theID as text)} to theAlbum
                        set addedCount to addedCount + 1
                    end try
                end repeat
                return addedCount
            end tell
            """

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }.value
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == PHPhotosErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case 3300: return "Photos reported that this change isn't supported for these photos (error 3300)."
        case 3310, 3311: return "Access to Photos was denied. Allow ZoomCheck in System Settings → Privacy & Security → Photos."
        default: return "\(error.localizedDescription) (\(ns.domain) \(ns.code))"
        }
    }
}

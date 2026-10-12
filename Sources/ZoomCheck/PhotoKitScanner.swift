import AVFoundation
import Foundation
import ImageIO
import Photos

/// Reads zoom metadata through PhotoKit, for when ZoomCheck has no Full Disk Access.
///
/// PhotoKit exposes date, location and media type, but not focal length or lens. Those live in the
/// original file, so every photo or video has to be opened (and downloaded from iCloud if needed).
/// Results are cached, so each item is only read once.
enum PhotoKitScanner {
    enum Outcome: Sendable {
        /// An iPhone photo or video with zoom data.
        case record(PhotoRecord)
        /// Read successfully, but not usable (other camera, no zoom data). Cached, never read again.
        case ignored
        /// Couldn't be read now (e.g. a video only in iCloud). Not cached, retried on the next scan.
        case unavailable
    }

    /// What ZoomCheck knows about an asset without opening its file.
    struct AssetInfo: Sendable {
        let uuid: String
        let isVideo: Bool
        let date: Date?
        let latitude: Double?
        let longitude: Double?

        init(_ asset: PHAsset) {
            uuid = PhotoKitScanner.uuid(of: asset)
            isVideo = asset.mediaType == .video
            date = asset.creationDate
            if let coordinate = asset.location?.coordinate,
               (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
               !(coordinate.latitude == 0 && coordinate.longitude == 0) {
                latitude = coordinate.latitude
                longitude = coordinate.longitude
            } else {
                latitude = nil
                longitude = nil
            }
        }

        func record(mm35: Int, focal: Double?, lensModel: String?, model: String?) -> PhotoRecord {
            PhotoRecord(
                uuid: uuid,
                isVideo: isVideo,
                mm35: mm35,
                focal: focal,
                isFrontCamera: lensModel?.localizedCaseInsensitiveContains("front") ?? false,
                model: model ?? "Unknown iPhone",
                date: date,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    struct CachedItem: Codable {
        /// nil when the item was read but isn't usable.
        var record: PhotoRecord?
    }

    /// The ZUUID part of a local identifier ("<UUID>/L0/001"), matching the database mode.
    static func uuid(of asset: PHAsset) -> String {
        asset.localIdentifier.components(separatedBy: "/").first ?? asset.localIdentifier
    }

    // MARK: - Fetching

    private static func baseOptions(includeVideos: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.predicate = includeVideos
            ? NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    static func allAssetUUIDs() -> Set<String> {
        var ids = Set<String>()
        PHAsset.fetchAssets(with: baseOptions(includeVideos: true)).enumerateObjects { asset, _, _ in
            ids.insert(uuid(of: asset))
        }
        return ids
    }

    /// Assets matching the filters that PhotoKit can check without opening files. Screenshots are skipped.
    static func candidates(region: Region?, dateRange: ClosedRange<Date>?, includeVideos: Bool) -> [PHAsset] {
        let options = baseOptions(includeVideos: includeVideos)
        if let dateRange, let typePredicate = options.predicate {
            let datePredicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            dateRange.lowerBound as NSDate, dateRange.upperBound as NSDate)
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [typePredicate, datePredicate])
        }

        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { return }
            if let region {
                guard let coordinate = asset.location?.coordinate,
                      region.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
                else { return }
            }
            assets.append(asset)
        }
        return assets
    }

    // MARK: - Reading

    static func read(_ asset: PHAsset, info: AssetInfo, allowVideoDownload: Bool) async -> Outcome {
        info.isVideo
            ? await readVideo(asset, info: info, allowDownload: allowVideoDownload)
            : await readPhoto(asset, info: info)
    }

    /// Streams the original and stops as soon as the metadata can be parsed, which for most
    /// photos is well before the whole file has been downloaded.
    private static func readPhoto(_ asset: PHAsset, info: AssetInfo) async -> Outcome {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first
        else { return .ignored }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let state = PhotoRequestState()

        return await withCheckedContinuation { continuation in
            state.continuation = continuation
            let id = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    guard let snapshot = state.append(chunk) else { return }
                    if let outcome = parsePhoto(snapshot, final: false, info: info), state.finish(outcome) {
                        state.cancelRequest()
                    }
                },
                completionHandler: { error in
                    if error != nil {
                        state.finish(.unavailable)
                    } else {
                        state.finish(parsePhoto(state.allData(), final: true, info: info) ?? .ignored)
                    }
                }
            )
            state.setRequestID(id)
        }
    }

    /// Returns nil when more data is needed.
    private static func parsePhoto(_ data: Data, final: Bool, info: AssetInfo) -> Outcome? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let make = tiff[kCGImagePropertyTIFFMake] as? String
        else { return final ? .ignored : nil }

        guard make.trimmingCharacters(in: .whitespaces) == "Apple" else { return .ignored }

        let mm35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue ?? 0
        let lensModel = exif[kCGImagePropertyExifLensModel] as? String
        let exifFocal = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue ?? 0
        let focal = exifFocal > 0 ? exifFocal : lensModel.flatMap(PhotosDatabase.focalLength(fromLensModel:))
        guard mm35 > 0 || focal != nil else { return final ? .ignored : nil }

        return .record(info.record(mm35: mm35, focal: focal, lensModel: lensModel,
                                   model: tiff[kCGImagePropertyTIFFModel] as? String))
    }

    private static func readVideo(_ asset: PHAsset, info: AssetInfo, allowDownload: Bool) async -> Outcome {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowDownload
        options.version = .original
        options.deliveryMode = .highQualityFormat

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
        guard let avAsset else { return .unavailable }
        guard let items = try? await avAsset.load(.metadata) else { return .unavailable }

        func item(_ suffix: String) -> AVMetadataItem? {
            items.first { ($0.identifier?.rawValue ?? "").hasSuffix(suffix) }
        }
        func string(_ suffix: String) async -> String? {
            guard let item = item(suffix) else { return nil }
            return try? await item.load(.stringValue)
        }
        func number(_ suffix: String) async -> NSNumber? {
            guard let item = item(suffix) else { return nil }
            if let number = try? await item.load(.numberValue) { return number }
            if let text = try? await item.load(.stringValue), let value = Double(text) { return NSNumber(value: value) }
            return nil
        }

        guard await string("quicktime.make") == "Apple" else { return .ignored }
        let lensModel = await string("camera.lens_model")
        let mm35 = await number("camera.focal_length.35mm_equivalent")?.intValue ?? 0
        let focal = lensModel.flatMap(PhotosDatabase.focalLength(fromLensModel:))
        guard mm35 > 0 || focal != nil else { return .ignored }

        return .record(info.record(mm35: mm35, focal: focal, lensModel: lensModel,
                                   model: await string("quicktime.model")))
    }

    // MARK: - Cache

    private static var cacheURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("ZoomCheck/photokit-cache.json")
    }

    static func loadCache() -> [String: CachedItem] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedItem].self, from: data)) ?? [:]
    }

    static func clearCache() {
        guard let url = cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func saveCache(_ cache: [String: CachedItem]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Shared state between the PhotoKit data callbacks, which arrive on arbitrary threads.
private final class PhotoRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var nextParseAt = 64 * 1024
    private var finished = false
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelPending = false
    var continuation: CheckedContinuation<PhotoKitScanner.Outcome, Never>?

    /// Appends a chunk; returns a snapshot when it's time to try parsing again.
    func append(_ chunk: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        data.append(chunk)
        guard data.count >= nextParseAt else { return nil }
        nextParseAt = data.count + 256 * 1024
        return data
    }

    func allData() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    /// Resumes the continuation once; later calls are ignored.
    @discardableResult
    func finish(_ outcome: PhotoKitScanner.Outcome) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        data = Data()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
        return true
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelPending
        lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancelRequest() {
        lock.lock()
        let id = requestID
        if id == nil { cancelPending = true }
        lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}

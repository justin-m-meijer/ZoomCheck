import Foundation
import Observation
import Photos

enum LibraryMode {
    /// Reads a copy of Photos.sqlite. Fast, needs Full Disk Access.
    case database
    /// Opens each original through PhotoKit. Needs only Photos access.
    case photoKit
}

@MainActor
@Observable
final class AppModel {
    static let zoomOptions: [Double] = [1, 2, 3, 4, 5, 8]

    var libraryURL = PhotosDatabase.defaultLibraryURL
    var records: [PhotoRecord] = []
    var profile = CameraProfile()
    var availableModels: [(model: String, count: Int)] = []
    var isLoading = false
    var loadError: PhotosDatabaseError?
    var otherError: String?

    var targetZoom: Double = 2
    var regionID: String = Region.everywhereID
    var customLatMin = 24.0
    var customLatMax = 46.0
    var customLonMin = 122.0
    var customLonMax = 146.0
    var includeVideos = true
    var excludedModels: Set<String> = []
    var useDateRange = false
    var startDate = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    var endDate = Date.now

    var albumStatus: String?
    var isCreatingAlbum = false

    // MARK: Photos access mode
    var mode: LibraryMode = .database
    var photoAccessGranted = false
    var allowICloudVideoDownloads = false
    /// Items matching the current date/region filter that haven't been read yet.
    var pendingAssets: [PHAsset] = []
    var matchingCount = 0
    var isScanning = false
    var scanDone = 0
    var scanTotal = 0
    var scanUnavailable = 0
    private var cache: [String: PhotoKitScanner.CachedItem] = [:]
    private var scanTask: Task<Void, Never>?

    /// Changes whenever the set of items to scan could change.
    var estimateKey: String {
        [
            "\(mode)", "\(photoAccessGranted)", regionID,
            "\(customLatMin),\(customLatMax),\(customLonMin),\(customLonMax)",
            "\(useDateRange)", "\(startDate.timeIntervalSince1970)", "\(endDate.timeIntervalSince1970)",
            "\(includeVideos)",
        ].joined(separator: "|")
    }

    var region: Region? {
        if regionID == Region.everywhereID { return nil }
        if regionID == Region.customID {
            let lat = min(customLatMin, customLatMax)...max(customLatMin, customLatMax)
            let lon = min(customLonMin, customLonMax)...max(customLonMin, customLonMax)
            return Region(id: Region.customID, name: "Custom area", latitude: lat, longitude: lon)
        }
        return Region.presets.first { $0.id == regionID }
    }

    var filters: Filters {
        var range: ClosedRange<Date>?
        if useDateRange {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: min(startDate, endDate))
            let endDay = calendar.startOfDay(for: max(startDate, endDate))
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDay
            range = start...end
        }
        return Filters(targetZoom: targetZoom, region: region, dateRange: range,
                       includeVideos: includeVideos, excludedModels: excludedModels)
    }

    var result: AnalysisResult {
        Analysis.run(records: records, profile: profile, filters: filters)
    }

    func load() async {
        isLoading = true
        loadError = nil
        otherError = nil
        albumStatus = nil
        let url = libraryURL
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try PhotosDatabase.load(libraryURL: url)
            }.value
            mode = .database
            apply(records: loaded)
        } catch let error as PhotosDatabaseError {
            records = []
            if case .accessDenied = error {
                // No Full Disk Access: fall back to reading files through PhotoKit.
                isLoading = false
                await enterPhotoKitMode()
                return
            }
            loadError = error
        } catch {
            records = []
            otherError = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(records loaded: [PhotoRecord]) {
        records = loaded
        profile = Analysis.profile(loaded)
        availableModels = Analysis.modelCounts(loaded)
        excludedModels = excludedModels.intersection(Set(availableModels.map(\.model)))
    }

    // MARK: - Photos access mode

    func enterPhotoKitMode() async {
        mode = .photoKit
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = status == .authorized || status == .limited
        guard photoAccessGranted else { return }

        // Forget items that have since been deleted.
        let existing = PhotoKitScanner.allAssetUUIDs()
        cache = PhotoKitScanner.loadCache().filter { existing.contains($0.key) }
        apply(records: cache.values.compactMap(\.record))
        await refreshEstimate()
    }

    func refreshEstimate() async {
        guard mode == .photoKit, photoAccessGranted, !isScanning else { return }
        let f = filters
        let candidates = PhotoKitScanner.candidates(region: f.region, dateRange: f.dateRange, includeVideos: f.includeVideos)
        matchingCount = candidates.count
        pendingAssets = candidates.filter { cache[PhotoKitScanner.uuid(of: $0)] == nil }
    }

    func startScan() {
        guard !isScanning, !pendingAssets.isEmpty else { return }
        scanTask = Task { await scan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func scan() async {
        let assets = pendingAssets
        let allowVideoDownload = allowICloudVideoDownloads
        isScanning = true
        scanTotal = assets.count
        scanDone = 0
        scanUnavailable = 0
        albumStatus = nil

        await withTaskGroup(of: (String, PhotoKitScanner.Outcome).self) { group in
            var iterator = assets.makeIterator()
            func enqueue(_ asset: PHAsset) {
                let info = PhotoKitScanner.AssetInfo(asset)
                group.addTask {
                    let outcome = await PhotoKitScanner.read(asset, info: info, allowVideoDownload: allowVideoDownload)
                    return (info.uuid, outcome)
                }
            }
            for _ in 0..<6 {
                guard let asset = iterator.next() else { break }
                enqueue(asset)
            }
            while let next = await group.next() {
                let (uuid, outcome) = next
                switch outcome {
                case .record(let record): cache[uuid] = PhotoKitScanner.CachedItem(record: record)
                case .ignored: cache[uuid] = PhotoKitScanner.CachedItem(record: nil)
                case .unavailable: scanUnavailable += 1
                }
                scanDone += 1
                if scanDone % 200 == 0 {
                    PhotoKitScanner.saveCache(cache)
                    apply(records: cache.values.compactMap(\.record))
                }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let asset = iterator.next() { enqueue(asset) }
            }
        }

        PhotoKitScanner.saveCache(cache)
        apply(records: cache.values.compactMap(\.record))
        isScanning = false
        await refreshEstimate()
    }

    func createAlbum() async {
        let uuids = result.beyondTeleUUIDs
        var name = "ZoomCheck – beyond \(ZoomFormat.string(targetZoom))"
        if let region { name += " – \(region.name)" }

        isCreatingAlbum = true
        albumStatus = nil
        do {
            let outcome = try await AlbumCreator.addToAlbum(named: name, uuids: uuids)
            var status = "Added \(outcome.added) items to the album “\(outcome.name)”."
            if outcome.skipped > 0 {
                status += " \(outcome.skipped) couldn't be added (for example items from shared albums)."
            }
            albumStatus = status
        } catch {
            albumStatus = error.localizedDescription
        }
        isCreatingAlbum = false
    }
}

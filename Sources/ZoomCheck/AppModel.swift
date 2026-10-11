import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let zoomOptions: [Double] = [1, 2, 3, 4, 5, 8]

    var libraryURL = PhotosDatabase.defaultLibraryURL
    var records: [PhotoRecord] = []
    var mainFocal: [String: Double] = [:]
    var isLoading = false
    var loadError: PhotosDatabaseError?
    var otherError: String?

    var targetZoom: Double = 2
    var regionID: String = Region.everywhereID
    var customLatMin = 24.0
    var customLatMax = 46.0
    var customLonMin = 122.0
    var customLonMax = 146.0
    var useDateRange = false
    var startDate = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    var endDate = Date.now

    var albumStatus: String?
    var isCreatingAlbum = false

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
        return Filters(targetZoom: targetZoom, region: region, dateRange: range)
    }

    var result: AnalysisResult {
        Analysis.run(records: records, mainFocal: mainFocal, filters: filters)
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
            records = loaded
            mainFocal = Analysis.mainFocalByModel(loaded)
        } catch let error as PhotosDatabaseError {
            records = []
            loadError = error
        } catch {
            records = []
            otherError = error.localizedDescription
        }
        isLoading = false
    }

    func createAlbum() async {
        let uuids = result.beyondTeleUUIDs
        var name = "ZoomCheck – beyond \(ZoomFormat.string(targetZoom))"
        if let region { name += " – \(region.name)" }

        isCreatingAlbum = true
        albumStatus = nil
        do {
            let count = try await AlbumCreator.createAlbum(named: name, uuids: uuids)
            albumStatus = "Created album “\(name)” with \(count) photos."
        } catch {
            albumStatus = error.localizedDescription
        }
        isCreatingAlbum = false
    }
}

import Foundation

enum Bucket: Int, CaseIterable, Identifiable {
    case ultraWide, main, withinTarget, beyondCrop, beyondTele

    var id: Int { rawValue }

    func title(target: Double) -> String {
        switch self {
        case .ultraWide: return "0.5x"
        case .main: return "1x"
        case .withinTarget: return target <= 2 ? "2x" : "2x – \(ZoomFormat.string(target))"
        case .beyondCrop: return "> \(ZoomFormat.string(target)) · main-camera crop"
        case .beyondTele: return "> \(ZoomFormat.string(target)) · telephoto lens"
        }
    }

    /// Shots the target phone could not have taken the same way.
    var isLoss: Bool { self == .beyondTele }
}

enum ZoomFormat {
    static func string(_ zoom: Double) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))x" : String(format: "%.1fx", zoom)
    }
}

struct Region: Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: ClosedRange<Double>
    let longitude: ClosedRange<Double>

    func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        latitude.contains(lat) && longitude.contains(lon)
    }

    static let everywhereID = "everywhere"
    static let customID = "custom"

    /// Rough bounding boxes; edges overlap with neighbouring countries.
    static let presets: [Region] = [
        Region(id: "jp", name: "Japan", latitude: 24...46, longitude: 122...146),
        Region(id: "nl", name: "Netherlands", latitude: 50.7...53.6, longitude: 3.3...7.3),
        Region(id: "fr", name: "France", latitude: 41.3...51.1, longitude: -5.2...9.6),
        Region(id: "it", name: "Italy", latitude: 36.6...47.1, longitude: 6.6...18.6),
        Region(id: "us", name: "United States (contiguous)", latitude: 24.4...49.4, longitude: -125.0...(-66.9)),
    ]
}

struct Filters {
    var targetZoom: Double
    var region: Region?
    var dateRange: ClosedRange<Date>?
    var includeVideos: Bool
    /// Camera models to leave out (e.g. someone else's iPhone whose photos are in your library).
    var excludedModels: Set<String>
}

struct ModelRow: Identifiable {
    let id: String
    var photos = 0
    var videos = 0
    var beyondCrop = 0
    var beyondTele = 0

    var total: Int { photos + videos }
}

struct AnalysisResult {
    var counts: [Bucket: Int] = [:]
    var total = 0
    var photos = 0
    var videos = 0
    var excludedWithoutLocation = 0
    var beyondTeleUUIDs: [String] = []
    var models: [ModelRow] = []

    func count(_ bucket: Bucket) -> Int { counts[bucket, default: 0] }

    func percent(_ bucket: Bucket) -> Double {
        total == 0 ? 0 : 100 * Double(count(bucket)) / Double(total)
    }
}

/// What ZoomCheck learns about each iPhone model from its photos.
struct CameraProfile: Sendable {
    /// Real focal length of each model's main (1x) camera.
    var mainFocal: [String: Double] = [:]
    /// 35mm equivalent of each model's 1x (24 mm on recent iPhones, 26–28 mm on older ones).
    var oneX35mm: [String: Double] = [:]
    /// Per model: the lenses seen in photos, with the 35mm value they usually shoot at.
    var lenses: [String: [Lens]] = [:]

    struct Lens: Sendable {
        let focal: Double
        let native35mm: Int
    }

    func lens(model: String, focal: Double) -> Lens? {
        lenses[model]?
            .filter { abs($0.focal - focal) < 0.35 }
            .min { abs($0.focal - focal) < abs($1.focal - focal) }
    }
}

enum Analysis {
    /// 35mm equivalent of 1x when a model's own value is unknown.
    static let baseline35mm = 24.0
    /// Margin above the target zoom so e.g. older 52mm "2x" lenses still count as 2x.
    static let tolerance = 1.15

    static func profile(_ records: [PhotoRecord]) -> CameraProfile {
        var profile = CameraProfile()

        // Main camera: median real focal length of each model's 1x photos.
        var oneX: [String: [Double]] = [:]
        // Lenses: per model and focal length (0.1 mm buckets), how often each 35mm value occurs.
        var histogram: [String: [Int: [Int: Int]]] = [:]

        for record in records where !record.isVideo && !record.isFrontCamera && record.mm35 > 0 {
            guard let focal = record.focal else { continue }
            if (23...29).contains(record.mm35) {
                oneX[record.model, default: []].append(focal)
            }
            let key = Int((focal * 10).rounded())
            histogram[record.model, default: [:]][key, default: [:]][record.mm35, default: 0] += 1
        }

        for (model, values) in oneX {
            let sorted = values.sorted()
            profile.mainFocal[model] = sorted[sorted.count / 2]
        }
        for (model, byFocal) in histogram {
            profile.lenses[model] = byFocal.compactMap { key, counts in
                // The most common 35mm value is the lens's own zoom level; crops are less frequent.
                guard let native = counts.max(by: { $0.value < $1.value })?.key else { return nil }
                return CameraProfile.Lens(focal: Double(key) / 10, native35mm: native)
            }
        }
        for (model, main) in profile.mainFocal {
            if let lens = profile.lens(model: model, focal: main) {
                profile.oneX35mm[model] = Double(lens.native35mm)
            }
        }
        return profile
    }

    static func bucket(for record: PhotoRecord, target: Double, profile: CameraProfile) -> Bucket {
        let main = profile.mainFocal[record.model]
        let oneX = profile.oneX35mm[record.model] ?? baseline35mm

        func isMainLens(_ focal: Double?) -> Bool {
            guard let focal else { return false }
            if let main { return abs(focal - main) < 0.35 }
            return focal < 7
        }

        func bucket(mm35 mm: Double) -> Bucket? {
            let zoom = mm / oneX
            if zoom < 0.8 { return .ultraWide }
            if zoom <= target * tolerance { return zoom < 1.5 ? .main : .withinTarget }
            return nil
        }

        if record.isFrontCamera { return .main }

        // Known zoom level (all photos, and videos from some models).
        if record.mm35 > 0 {
            if let within = bucket(mm35: Double(record.mm35)) { return within }
            return isMainLens(record.focal) ? .beyondCrop : .beyondTele
        }

        // Only the lens is known (videos from e.g. iPhone 16/17). The main lens covers 1x and its 2x crop.
        guard let focal = record.focal else { return .main }
        if isMainLens(focal) { return .main }
        if let lens = profile.lens(model: record.model, focal: focal) {
            return bucket(mm35: Double(lens.native35mm)) ?? .beyondTele
        }
        // Lens never seen in photos: estimate from the main camera.
        if let main {
            if focal < main { return .ultraWide }
            return bucket(mm35: oneX * focal / main) ?? .beyondTele
        }
        return focal < 3 ? .ultraWide : .beyondTele
    }

    static func run(records: [PhotoRecord], profile: CameraProfile, filters: Filters) -> AnalysisResult {
        var result = AnalysisResult()
        var models: [String: ModelRow] = [:]

        for record in records {
            if record.isVideo && !filters.includeVideos { continue }
            if filters.excludedModels.contains(record.model) { continue }
            if let range = filters.dateRange {
                guard let date = record.date, range.contains(date) else { continue }
            }
            if let region = filters.region {
                guard let lat = record.latitude, let lon = record.longitude else {
                    result.excludedWithoutLocation += 1
                    continue
                }
                guard region.contains(latitude: lat, longitude: lon) else { continue }
            }

            let bucket = bucket(for: record, target: filters.targetZoom, profile: profile)
            result.counts[bucket, default: 0] += 1
            result.total += 1

            var row = models[record.model] ?? ModelRow(id: record.model)
            if record.isVideo {
                row.videos += 1
                result.videos += 1
            } else {
                row.photos += 1
                result.photos += 1
            }
            switch bucket {
            case .beyondTele:
                row.beyondTele += 1
                result.beyondTeleUUIDs.append(record.uuid)
            case .beyondCrop:
                row.beyondCrop += 1
            default:
                break
            }
            models[record.model] = row
        }

        result.models = models.values.sorted { $0.total > $1.total }
        return result
    }

    /// All models in the library, most items first.
    static func modelCounts(_ records: [PhotoRecord]) -> [(model: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records { counts[record.model, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }
}

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

    /// Photos the target phone could not have taken the same way.
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
}

struct ModelRow: Identifiable {
    let id: String
    var total = 0
    var beyondCrop = 0
    var beyondTele = 0
}

struct AnalysisResult {
    var counts: [Bucket: Int] = [:]
    var total = 0
    var excludedWithoutLocation = 0
    var beyondTeleUUIDs: [String] = []
    var models: [ModelRow] = []

    func count(_ bucket: Bucket) -> Int { counts[bucket, default: 0] }

    func percent(_ bucket: Bucket) -> Double {
        total == 0 ? 0 : 100 * Double(count(bucket)) / Double(total)
    }
}

enum Analysis {
    /// 35mm equivalent of 1x on recent iPhones (older models use 26mm).
    static let baseline35mm = 24.0
    /// Margin above the target zoom so e.g. older 52mm "2x" lenses still count as 2x.
    static let tolerance = 1.15

    /// Median real focal length of each model's 1x shots = its main camera.
    /// Used to tell a main-camera crop (same lens, higher 35mm value) from a real telephoto shot.
    static func mainFocalByModel(_ records: [PhotoRecord]) -> [String: Double] {
        var groups: [String: [Double]] = [:]
        for record in records where (23...27).contains(record.mm35) && record.focal > 0 {
            groups[record.model, default: []].append(record.focal)
        }
        return groups.compactMapValues { values in
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    static func bucket(for record: PhotoRecord, target: Double, mainFocal: [String: Double]) -> Bucket {
        let mm = Double(record.mm35)
        let limit = target * baseline35mm * tolerance
        if mm < 20 { return .ultraWide }
        if mm <= limit { return mm < 47 ? .main : .withinTarget }

        let isCrop: Bool
        if let main = mainFocal[record.model] {
            isCrop = abs(record.focal - main) < 0.35
        } else {
            isCrop = record.focal < 7
        }
        return isCrop ? .beyondCrop : .beyondTele
    }

    static func run(records: [PhotoRecord], mainFocal: [String: Double], filters: Filters) -> AnalysisResult {
        var result = AnalysisResult()
        var models: [String: ModelRow] = [:]

        for record in records {
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

            let bucket = bucket(for: record, target: filters.targetZoom, mainFocal: mainFocal)
            result.counts[bucket, default: 0] += 1
            result.total += 1

            var row = models[record.model] ?? ModelRow(id: record.model)
            row.total += 1
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
}

import Foundation
import SQLite3

/// One iPhone photo or video with the metadata ZoomCheck needs.
struct PhotoRecord: Sendable, Codable {
    let uuid: String
    let isVideo: Bool
    /// 35mm-equivalent focal length (reflects the zoom level, including main-camera crops). 0 when unknown.
    let mm35: Int
    /// Real focal length of the lens, in mm: from EXIF, or parsed from the lens model. nil when unknown.
    let focal: Double?
    let isFrontCamera: Bool
    let model: String
    let date: Date?
    let latitude: Double?
    let longitude: Double?
}

enum PhotosDatabaseError: LocalizedError {
    case libraryNotFound(String)
    case accessDenied(String)
    case notAPhotosLibrary(String)
    case openFailed(String)
    case schemaMismatch([String])
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound(let path):
            return "No Photos library found at \(path)."
        case .accessDenied:
            return "macOS blocked access to the Photos library. ZoomCheck needs Full Disk Access to read it."
        case .notAPhotosLibrary(let path):
            return "\(path) doesn't look like a Photos library (no database/Photos.sqlite inside)."
        case .openFailed(let message):
            return "Couldn't open the Photos database: \(message)"
        case .schemaMismatch(let columns):
            return "This version of Photos uses a database layout ZoomCheck doesn't recognise. Missing: \(columns.joined(separator: ", "))"
        case .queryFailed(let message):
            return "Reading the Photos database failed: \(message)"
        }
    }
}

/// Reads a *copy* of the Photos database. The live library is never opened or modified.
enum PhotosDatabase {
    static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
    }

    private static let requiredColumns: [String: [String]] = [
        "ZASSET": ["Z_PK", "ZUUID", "ZKIND", "ZTRASHEDSTATE", "ZDATECREATED", "ZLATITUDE", "ZLONGITUDE"],
        "ZEXTENDEDATTRIBUTES": ["ZASSET", "ZFOCALLENGTHIN35MM", "ZFOCALLENGTH", "ZCAMERAMAKE", "ZCAMERAMODEL", "ZLENSMODEL"],
    ]

    private static let query = """
        SELECT a.ZUUID, e.ZFOCALLENGTHIN35MM, e.ZFOCALLENGTH, e.ZCAMERAMODEL,
               a.ZDATECREATED, a.ZLATITUDE, a.ZLONGITUDE, a.ZKIND, e.ZLENSMODEL
        FROM ZASSET a
        JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
        WHERE e.ZCAMERAMAKE = 'Apple'
          AND a.ZKIND IN (0, 1)
          AND a.ZTRASHEDSTATE = 0
        """

    static func load(libraryURL: URL) throws -> [PhotoRecord] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PhotosDatabaseError.libraryNotFound(libraryURL.path)
        }

        let databaseDir = libraryURL.appendingPathComponent("database", isDirectory: true)
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: databaseDir.path)
        } catch {
            if isPermissionError(error) { throw PhotosDatabaseError.accessDenied(libraryURL.path) }
            throw PhotosDatabaseError.notAPhotosLibrary(libraryURL.path)
        }

        // Copy the database together with its WAL files so recent changes are included.
        let wanted = ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"].filter { names.contains($0) }
        guard wanted.contains("Photos.sqlite") else {
            throw PhotosDatabaseError.notAPhotosLibrary(libraryURL.path)
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("ZoomCheck-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        for name in wanted {
            do {
                try fm.copyItem(at: databaseDir.appendingPathComponent(name), to: tempDir.appendingPathComponent(name))
            } catch {
                if isPermissionError(error) { throw PhotosDatabaseError.accessDenied(libraryURL.path) }
                throw error
            }
        }

        return try read(databaseAt: tempDir.appendingPathComponent("Photos.sqlite"))
    }

    // MARK: - SQLite

    private static func read(databaseAt url: URL) throws -> [PhotoRecord] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw PhotosDatabaseError.openFailed(message)
        }
        defer { sqlite3_close(db) }

        var missing: [String] = []
        for (table, columns) in requiredColumns {
            let present = try self.columns(of: table, in: db)
            missing += columns.filter { !present.contains($0) }.map { "\(table).\($0)" }
        }
        guard missing.isEmpty else { throw PhotosDatabaseError.schemaMismatch(missing.sorted()) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw PhotosDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var records: [PhotoRecord] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw PhotosDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            guard let uuid = text(statement, 0) else { continue }

            let date: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4))

            // Photos stores -180/-180 for "no location".
            var latitude: Double?
            var longitude: Double?
            if sqlite3_column_type(statement, 5) != SQLITE_NULL, sqlite3_column_type(statement, 6) != SQLITE_NULL {
                let lat = sqlite3_column_double(statement, 5)
                let lon = sqlite3_column_double(statement, 6)
                if (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) {
                    latitude = lat
                    longitude = lon
                }
            }

            let lensModel = text(statement, 8)
            let exifFocal = sqlite3_column_double(statement, 2)
            let mm35 = Int(sqlite3_column_int64(statement, 1))
            let focal: Double? = exifFocal > 0 ? exifFocal : lensModel.flatMap(focalLength(fromLensModel:))
            // Without a 35mm value or a lens there is nothing to classify.
            guard mm35 > 0 || focal != nil else { continue }

            records.append(PhotoRecord(
                uuid: uuid,
                isVideo: sqlite3_column_int64(statement, 7) == 1,
                mm35: mm35,
                focal: focal,
                isFrontCamera: lensModel?.localizedCaseInsensitiveContains("front") ?? false,
                model: text(statement, 3) ?? "Unknown iPhone",
                date: date,
                latitude: latitude,
                longitude: longitude
            ))
        }
        return records
    }

    private static func columns(of table: String, in db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw PhotosDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
    }

    /// "iPhone 17 Pro Max back camera 16.891mm f/2.8" → 16.891 (also handles a decimal comma).
    static func focalLength(fromLensModel lens: String) -> Double? {
        guard let match = lens.firstMatch(of: #/([0-9]+(?:[.,][0-9]+)?)\s*mm/#) else { return nil }
        let value = Double(match.1.replacingOccurrences(of: ",", with: "."))
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }
}

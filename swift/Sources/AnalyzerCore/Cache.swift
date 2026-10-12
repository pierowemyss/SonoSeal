// SQLite results cache: a file is re-analyzed only when its mtime or size changes. Port of cache.py.
import Foundation
import SQLite3

public actor Cache {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    public init(path: String) {
        sqlite3_open(path, &db)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS results "
                     + "(path TEXT PRIMARY KEY, mtime REAL, size INTEGER, data TEXT, spectrum BLOB)", nil, nil, nil)
    }

    public static var defaultPath: String {
        let dir = URL.applicationSupportDirectory.appending(path: "MusicLibraryAnalyzer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "results.sqlite").path
    }

    public func get(_ path: String, mtime: Double, size: Int) -> TrackResult? {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "SELECT data, spectrum FROM results WHERE path=? AND mtime=? AND size=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient)
        sqlite3_bind_double(st, 2, mtime)
        sqlite3_bind_int64(st, 3, Int64(size))
        guard sqlite3_step(st) == SQLITE_ROW, let text = sqlite3_column_text(st, 0),
              var r = try? JSONDecoder().decode(TrackResult.self, from: Data(String(cString: text).utf8)) else { return nil }
        if let blob = sqlite3_column_blob(st, 1) {
            let n = Int(sqlite3_column_bytes(st, 1)) / 2
            r.spectrum = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float16.self), count: n).map(Float.init)
        }
        return r
    }

    public func put(_ r: TrackResult, mtime: Double, size: Int) {
        var row = r
        row.spectrum = nil
        guard let data = try? JSONEncoder().encode(row) else { return }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO results VALUES (?,?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, r.path, -1, transient)
        sqlite3_bind_double(st, 2, mtime)
        sqlite3_bind_int64(st, 3, Int64(size))
        sqlite3_bind_text(st, 4, String(decoding: data, as: UTF8.self), -1, transient)
        if let spec = r.spectrum {
            let half = spec.map(Float16.init)
            half.withUnsafeBytes { _ = sqlite3_bind_blob(st, 5, $0.baseAddress, Int32($0.count), transient) }
        }
        sqlite3_step(st)
    }

    public func remove(_ path: String) {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "DELETE FROM results WHERE path=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient)
        sqlite3_step(st)
    }
}

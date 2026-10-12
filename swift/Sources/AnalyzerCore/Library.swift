// Inputs (folders, dropped files, Rekordbox XML, M3U) and outputs (CSV, Finder tags, Trash).
import Foundation

func isAudio(_ u: URL) -> Bool { AUDIO_EXTS.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.hasPrefix(".") }

/// Audio files under the given folders/files, sorted by path.
public func audioFiles(_ urls: [URL]) -> [URL] {
    var out: [URL] = []
    for u in urls {
        if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let f = e?.nextObject() as? URL { if isAudio(f) { out.append(f) } }
        } else if isAudio(u) {
            out.append(u)
        }
    }
    return out.sorted { $0.path < $1.path }
}

/// Track files listed in a Rekordbox XML export (.xml) or an M3U/M3U8 playlist.
public func readPlaylist(_ url: URL) throws -> [URL] {
    let data = try Data(contentsOf: url)
    if url.pathExtension.lowercased() == "xml" {
        let p = XMLParser(data: data), d = RekordboxReader()
        p.delegate = d
        guard p.parse() else { throw p.parserError ?? CocoaError(.fileReadCorruptFile) }
        return d.urls
    }
    let dir = url.deletingLastPathComponent()
    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { return nil }
        if s.hasPrefix("file:") { return URL(string: s) }
        return s.hasPrefix("/") ? URL(fileURLWithPath: s) : dir.appending(path: s).standardizedFileURL
    }
}

final class RekordboxReader: NSObject, XMLParserDelegate {
    var urls: [URL] = []
    // COLLECTION/TRACK carries Location="file://localhost/..."; playlist TRACK nodes only carry Key
    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if name == "TRACK", let loc = attributes["Location"], let u = URL(string: loc), u.isFileURL { urls.append(u) }
    }
}

public func csv(_ results: [TrackResult]) -> String {
    func field(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacing("\"", with: "\"\""))\"" : s }
    func num(_ v: Double?, _ f: String = "%.1f") -> String { v.map { String(format: f, $0) } ?? "" }
    let head = "path,verdict,confidence,format,kbps,cutoff_khz,est_source,dr,peak_db,rms_db,clips,reason"
    return ([head] + results.map { r in
        [r.path, r.verdict, "\(r.confidence)", fmtOf(r), r.claimedKbps.map(String.init) ?? "",
         num(r.cutoffHz.map { $0 / 1000 }), r.estQuality, num(r.dr), num(r.peakDb), num(r.rmsDb),
         r.clipEvents.map(String.init) ?? "", r.reason].map(field).joined(separator: ",")
    }).joined(separator: "\n") + "\n"
}

public let TAGS = ["Fake": "Red", "Suspect": "Orange", "OK": "Green"]

/// Adds the verdict's Finder color tag; existing tags are kept.
// ponytail: additive only, a re-scan that changes the verdict leaves the old color; strip TAGS values first if that bites
public func applyTag(_ r: TrackResult) throws {
    guard let tag = TAGS[r.verdict] else { return }
    let u = URL(fileURLWithPath: r.path)
    let tags = try u.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    if !tags.contains(tag) { try (u as NSURL).setResourceValue(tags + [tag], forKey: .tagNamesKey) }
}

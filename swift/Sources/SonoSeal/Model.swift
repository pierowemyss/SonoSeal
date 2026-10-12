import AnalyzerCore
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

let COLORS: [String: Color] = ["Fake": Color(red: 0.90, green: 0.28, blue: 0.30), "Suspect": Color(red: 0.96, green: 0.65, blue: 0.14),
                               "OK": Color(red: 0.19, green: 0.64, blue: 0.42), "?": .gray, "Error": .gray]
let VERDICTS = ["Fake", "Suspect", "OK", "?", "Error"]

enum VerdictView: String, CaseIterable, Identifiable {
    case all = "All", suspect = "Suspect + Fake", fake = "Fake only"
    var id: Self { self }
    var verdicts: Set<String>? { self == .all ? nil : self == .fake ? ["Fake"] : ["Fake", "Suspect"] }
}

/// Min/max for one range filter. Bounds span the scanned data; a value at its bound = off (unmeasured rows stay visible).
struct RangeState {
    var lo = 0.0, hi = 1.0, minB = 0.0, maxB = 1.0, enabled = false
    let decimals: Int
    var eps: Double { pow(10, Double(-decimals)) / 2 }
    var loOn: Bool { lo > minB + eps }
    var hiOn: Bool { hi < maxB - eps }

    /// Fit to the data; ranges the user narrowed stay as they are.
    mutating func fit(_ values: [Double]) {
        enabled = !values.isEmpty
        guard let mn = values.min(), let mx = values.max() else { return }
        let (l, h) = (loOn, hiOn), k = pow(10, Double(decimals))  // round outward so the extremes stay inside
        minB = (mn * k).rounded(.down) / k
        maxB = (mx * k).rounded(.up) / k
        if !l { lo = minB }
        if !h { hi = maxB }
    }
}

extension TrackResult {  // non-optional sort keys for the Table
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var verdictRank: Int { ["Fake", "Suspect", "?", "Error", "OK"].firstIndex(of: verdict) ?? 5 }
    var sKbps: Int { claimedKbps ?? -1 }
    var sCutoff: Double { cutoffHz ?? -1 }
    var sEst: Int { estKbps(self) ?? 0 }
    var sDr: Double { dr ?? -1 }
    var sPeak: Double { peakDb ?? -999 }
    var sRms: Double { rmsDb ?? -999 }
    var sClips: Int { clipEvents ?? -1 }
    var format: String { fmtOf(self) }
    var sArtist: String { artist ?? "" }
    var sAdded: Date { added ?? .distantPast }
}

enum SortChoice: String, CaseIterable, Identifiable {
    case added = "Recently Added", name = "Name", artist = "Artist", path = "Folder"
    var id: Self { self }
    var order: [KeyPathComparator<TrackResult>] {
        switch self {
        case .added: [KeyPathComparator(\.sAdded, order: .reverse)]
        case .name: [KeyPathComparator(\.name)]
        case .artist: [KeyPathComparator(\.sArtist), KeyPathComparator(\.path)]  // path keeps albums together
        case .path: [KeyPathComparator(\.path)]
        }
    }
}

@Observable @MainActor final class Model {
    var results: [TrackResult] = []
    var filtered: [TrackResult] = []
    var selection: Set<String> = []
    var sortOrder = [KeyPathComparator(\TrackResult.path)] { didSet { refilter() } }
    var root: URL?  // the single opened folder, if there's exactly one
    var sources: [URL] = [] {  // what the current scan covers (folders, dropped items or playlist tracks)
        didSet { UserDefaults.standard.set(sources.filter(isDir).map(\.path), forKey: "folders") }
    }
    var scanning = false
    var total = 0
    var done = 0
    var started = Date.now
    var counts: [String: Int] = [:]
    var folders: [(path: String, name: String, fake: Int, total: Int)] = []  // one per opened folder
    var showInspector = true

    // filters
    var view = VerdictView.all { didSet { refilter() } }
    var folder: String? = "" {  // "" = All; List sets nil when clicking empty space, which also means All
        didSet { if folder == nil { folder = "" }; refilter() }
    }
    var search = "" { didSet { refilterSoon() } }
    var lossyOnly = false { didSet { refilterSoon() } }
    var ranges = Dictionary(uniqueKeysWithValues: RANGES.map { ($0.field, RangeState(decimals: $0.decimals)) }) {
        didSet { refilterSoon() }
    }

    let cache = Cache(path: Cache.defaultPath)
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var debounce: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        let paths = d.stringArray(forKey: "folders") ?? d.string(forKey: "root").map { [$0] } ?? []  // "root": pre-multi-folder key
        let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { open(urls) }
    }

    var selected: TrackResult? { selection.count == 1 ? results.first { $0.path == selection.first } : nil }
    var selectedResults: [TrackResult] { results.filter { selection.contains($0.path) } }

    // MARK: scanning
    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.directoryURL = root ?? URL.musicDirectory
        p.message = "Choose one or more music folders"
        guard p.runModal() == .OK else { return }
        // add to the open folders; skip any already covered by one (avoids scanning tracks twice)
        var all = sources.filter(isDir)
        for u in p.urls where !all.contains(where: { u.path == $0.path || u.path.hasPrefix($0.path + "/") }) { all.append(u) }
        open(all)
    }

    func removeFolder(_ path: String) { open(sources.filter { isDir($0) && $0.path != path }) }

    private func open(_ dirs: [URL]) {
        root = dirs.count == 1 ? dirs[0] : nil
        if dirs.isEmpty { stop(); sources = []; results = []; selection = []; refreshCounts(); refilter() } else { scan(dirs) }
    }

    func importPlaylist() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.xml, .m3uPlaylist, UTType(filenameExtension: "m3u8") ?? .m3uPlaylist]
        p.message = "Choose a Rekordbox XML export or an M3U/M3U8 playlist"
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            let tracks = try readPlaylist(u)
            root = nil
            scan(tracks)
        } catch { alert("Couldn't read \(u.lastPathComponent)", "\(error)") }
    }

    func drop(_ urls: [URL]) {
        let dirs = urls.filter(isDir)
        root = urls.count == 1 && dirs.count == 1 ? dirs[0] : nil
        scan(urls)
    }

    func rescan() { if !sources.isEmpty { scan(sources) } }

    func scan(_ urls: [URL]) {
        stop()
        let gen = UUID(); scanID = gen  // a cancelled scan still drains its in-flight jobs; drop them, or rows duplicate
        sources = urls
        results = []; selection = []; folder = ""
        done = 0; total = 0; started = .now; scanning = true
        refreshCounts(); refilter()
        let cache = cache
        scanTask = Task {
            let files = await Task.detached { audioFiles(urls) }.value
            total = files.count
            var pending: [TrackResult] = [], last = Date.now
            await withTaskGroup(of: TrackResult?.self) { group in
                var it = files.makeIterator()
                for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount {
                    if let f = it.next() { group.addTask { await Self.job(f, cache) } }
                }
                for await r in group {
                    if let r { pending.append(r) }
                    if let f = it.next(), !Task.isCancelled { group.addTask { await Self.job(f, cache) } }
                    if Date.now.timeIntervalSince(last) > 0.25, scanID == gen {  // batch UI updates; cache hits arrive thousands/sec
                        flush(&pending); last = .now
                    }
                }
            }
            guard scanID == gen else { return }
            flush(&pending)
            scanning = false
            fitRanges()
        }
    }

    func stop() { scanTask?.cancel() }

    nonisolated static func job(_ url: URL, _ cache: Cache) async -> TrackResult? {
        if Task.isCancelled { return nil }
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey])
        let mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0, size = v?.fileSize ?? 0
        var r: TrackResult
        if let c = await cache.get(url.path, mtime: mtime, size: size), c.version == VERSION {
            r = c
        } else {
            do {
                r = try analyze(url)
                r.artist = readArtist(url)
                await cache.put(r, mtime: mtime, size: size)
            } catch {  // unreadable/corrupt file: report it, don't cache it
                r = .error(url.path, error)
            }
        }
        if r.artist == nil { r.artist = readArtist(url) }  // ponytail: untagged files re-read each scan (header only, cheap)
        r.added = v?.addedToDirectoryDate ?? v?.creationDate
        return r
    }

    private func flush(_ pending: inout [TrackResult]) {
        results += pending
        done += pending.count
        pending = []
        refreshCounts()
        refilter()
    }

    var eta: String {
        guard scanning, done > 0, total > done else { return "" }
        return "ETA \(Int(Date.now.timeIntervalSince(started) / Double(done) * Double(total - done))) s"
    }

    // MARK: folders & tallies
    /// Path of the opened folder containing the track (nil for loose files / playlist tracks).
    func sourceFolder(of r: TrackResult) -> String? {
        sources.first { r.path.hasPrefix($0.path + "/") }?.path  // ponytail: linear scan, fine for a handful of folders
    }

    private func refreshCounts() {
        counts = Dictionary(grouping: results, by: \.verdict).mapValues(\.count)
        var acc: [String: (Int, Int)] = [:]
        for r in results {
            guard let k = sourceFolder(of: r) else { continue }
            acc[k, default: (0, 0)].0 += r.verdict == "Fake" ? 1 : 0
            acc[k, default: (0, 0)].1 += 1
        }
        folders = acc.map { ($0.key, URL(fileURLWithPath: $0.key).lastPathComponent, $0.value.0, $0.value.1) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: filtering
    func fitRanges() {
        for (f, _) in ranges {
            ranges[f]!.fit(results.compactMap { if case let .num(v)? = FIELDS[f]?($0) { v } else { nil } })
        }
    }

    var rangeConds: [Condition] {
        ranges.flatMap { f, s -> [Condition] in
            (s.loOn ? [Condition(f, ">=", .num(s.lo))] : []) + (s.hiOn ? [Condition(f, "<=", .num(s.hi))] : [])
        } + (lossyOnly ? [Condition("lossy", "=", .num(1))] : [])
    }

    var filtersActive: Bool { view != .all || folder != "" || !search.isEmpty || !rangeConds.isEmpty }

    func applyPreset(_ p: (name: String, ranges: [String: (Double?, Double?)], lossy: Bool)) {
        resetFilters()
        lossyOnly = p.lossy
        for (f, (lo, hi)) in p.ranges {
            ranges[f]!.lo = lo ?? ranges[f]!.minB
            ranges[f]!.hi = hi ?? ranges[f]!.maxB
        }
    }

    func resetFilters() {
        lossyOnly = false
        for f in ranges.keys { ranges[f]!.lo = ranges[f]!.minB; ranges[f]!.hi = ranges[f]!.maxB }
    }

    private func refilterSoon() {  // debounce typing and slider drags
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(for: .milliseconds(150)); if !Task.isCancelled { refilter() } }
    }

    func refilter() {
        var q = parseQuery(search)
        q.conds += rangeConds
        let verdicts = view.verdicts
        filtered = results.filter { r in
            (verdicts?.contains(r.verdict) ?? true) && (folder == "" || sourceFolder(of: r) == folder) && matches(r, q)
        }.sorted(using: sortOrder)
    }

    // MARK: actions (only ever on explicit user command)
    func targets(_ ids: Set<String>? = nil) -> [TrackResult] {
        let ids = ids ?? selection
        return ids.isEmpty ? [] : results.filter { ids.contains($0.path) }
    }

    func reveal(_ ids: Set<String>? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(targets(ids).map { URL(fileURLWithPath: $0.path) })
    }

    func copyPaths(_ ids: Set<String>? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(targets(ids).map(\.path).joined(separator: "\n"), forType: .string)
    }

    func exportCSV() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "\(root?.lastPathComponent ?? "Music Library") analysis.csv"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try csv(filtered).write(to: u, atomically: true, encoding: .utf8) } catch { alert("Export failed", "\(error)") }
    }

    func tag(_ ids: Set<String>? = nil) {
        let rs = targets(ids).filter { TAGS[$0.verdict] != nil }
        guard !rs.isEmpty else { return }
        guard confirm("Add Finder color tags to \(rs.count) file\(rs.count == 1 ? "" : "s")?",
                      "Fake = Red, Suspect = Orange, OK = Green. Existing tags are kept.", "Add Tags") else { return }
        let failed = rs.filter { (try? applyTag($0)) == nil }
        if !failed.isEmpty { alert("\(failed.count) file(s) couldn't be tagged", failed.prefix(5).map(\.path).joined(separator: "\n")) }
    }

    func trash(_ ids: Set<String>? = nil) {
        let rs = targets(ids)
        guard !rs.isEmpty else { return }
        let what = rs.count == 1 ? "“\(rs[0].name)”" : "\(rs.count) files"
        guard confirm("Move \(what) to the Trash?", "You can restore them from the Trash in Finder.", "Move to Trash") else { return }
        var gone = Set<String>(), failed: [String] = []
        for r in rs {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: r.path), resultingItemURL: nil)
                gone.insert(r.path)
                Task { await cache.remove(r.path) }
            } catch { failed.append(r.name) }
        }
        results.removeAll { gone.contains($0.path) }
        selection.subtract(gone)
        refreshCounts(); refilter()
        if !failed.isEmpty { alert("\(failed.count) file(s) couldn't be moved", failed.prefix(5).joined(separator: "\n")) }
    }

    private func confirm(_ title: String, _ text: String, _ action: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: action); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.runModal()
    }
}

private func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

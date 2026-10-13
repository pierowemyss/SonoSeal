// Query/filter language from app.py: "est<256 dr<7 techno" = conditions AND path words.
import Foundation

public enum FieldValue: Equatable, Sendable { case num(Double), text(String) }

public func fmtOf(_ r: TrackResult) -> String {
    let codec = r.codec ?? "?"
    var fmt = (codec.hasPrefix("pcm_") ? URL(fileURLWithPath: r.path).pathExtension : codec).uppercased()
    if let sr = r.sampleRate, sr > 0 {
        fmt += " \(g(Double(sr) / 1000))k" + (r.bitDepth.map { $0 > 0 ? "/\($0)" : "" } ?? "")
    }
    return fmt
}

public func estKbps(_ r: TrackResult) -> Int? {
    r.estQuality.split { !("0" ... "9").contains($0) }.first.flatMap { Int($0) } ?? r.claimedKbps  // not Regex: runs per row per filter
}

// query fields: name -> value from a result (nil = not measured -> condition fails)
nonisolated(unsafe) public let FIELDS: [String: (TrackResult) -> FieldValue?] = {
    let n = { (v: Double?) in v.map(FieldValue.num) }
    let i = { (v: Int?) in v.map { FieldValue.num(Double($0)) } }
    let nz = { (v: Double?, scale: Double) in v.flatMap { $0 != 0 ? FieldValue.num($0 / scale) : nil } }
    return [
        "kbps": { i($0.claimedKbps) }, "est": { i(estKbps($0)) }, "conf": { i($0.confidence) },
        "lossy": { r in r.lossless.map { .num($0 ? 0 : 1) } },
        "dr": { n($0.dr) }, "peak": { n($0.peakDb) }, "rms": { n($0.rmsDb) }, "crest": { n($0.crestDb) },
        "clips": { i($0.clipEvents) }, "clippct": { n($0.clipPct) }, "floor": { n($0.noiseFloorDb) },
        "corr": { n($0.correlation) }, "width": { n($0.widthPct) }, "balance": { n($0.balanceDb.map(abs)) },
        "bits": { i($0.bitDepth) }, "dur": { n($0.duration) }, "air": { n($0.bands?["Air"]) },
        "cutoff": { nz($0.cutoffHz, 1000) }, "rolloff": { nz($0.rolloffHz, 1000) },
        "sr": { nz($0.sampleRate.map(Double.init), 1000) },
        "codec": { r in r.codec.map(FieldValue.text) }, "verdict": { .text($0.verdict) }, "fmt": { .text(fmtOf($0)) },
    ]
}()

public struct Condition: Equatable, Sendable {
    public var field: String, op: String, value: FieldValue
    public init(_ field: String, _ op: String, _ value: FieldValue) { self.field = field; self.op = op; self.value = value }
}

public struct Query: Equatable, Sendable {
    public var conds: [Condition] = [], words: [String] = []
    public init(conds: [Condition] = [], words: [String] = []) { self.conds = conds; self.words = words }
    public var isEmpty: Bool { conds.isEmpty && words.isEmpty }
}

public func parseQuery(_ text: String) -> Query {
    var q = Query()
    for tok in text.split(whereSeparator: \.isWhitespace).map(String.init) {
        if let m = tok.wholeMatch(of: /(\w+)(<=|>=|!=|<|>|=)(.+)/), FIELDS[m.1.lowercased()] != nil {
            let v = Double(m.3).map(FieldValue.num) ?? .text(m.3.lowercased())
            q.conds.append(Condition(m.1.lowercased(), String(m.2), v))
        } else {
            q.words.append(searchKey(tok))
        }
    }
    return q
}

func compare(_ a: Double, _ op: String, _ b: Double) -> Bool {
    switch op {
    case "<": a < b
    case "<=": a <= b
    case ">": a > b
    case ">=": a >= b
    case "=": a == b
    default: a != b
    }
}

/// Path folded for word search (case + Unicode form: APFS names are often decomposed). Precompute it once per track.
public func searchKey(_ s: String) -> String { s.lowercased().precomposedStringWithCanonicalMapping }

/// Byte substring search on two folded strings; String.contains is ~10x slower and this runs per row per keystroke.
func has(_ hay: String, _ needle: String) -> Bool {
    var h = hay, n = needle
    return h.withUTF8 { hb in n.withUTF8 { nb in memmem(hb.baseAddress, hb.count, nb.baseAddress, nb.count) != nil } }
}

/// `key`: searchKey(r.path), pass it precomputed when filtering many rows.
public func matches(_ r: TrackResult, _ q: Query, key: String? = nil) -> Bool {
    // ponytail: AND only; split the query on '|' if OR is ever needed
    if !q.words.isEmpty {
        let path = key ?? searchKey(r.path)
        guard q.words.allSatisfy({ has(path, $0) }) else { return false }
    }
    for c in q.conds {
        guard let v = FIELDS[c.field]?(r) else { return false }
        switch (c.value, v) {
        case let (.text(want), _):  // text: = / != mean contains / doesn't contain
            let s = switch v { case let .text(t): t.lowercased(); case let .num(x): g(x) }
            guard c.op == "=" || c.op == "!=", s.contains(want) == (c.op == "=") else { return false }
        case let (.num(want), .num(x)):
            guard compare(x, c.op, want) else { return false }
        case (.num, .text):
            return false
        }
    }
    return true
}

extension TrackResult {
    public var name: String { (path as NSString).lastPathComponent }
}

/// Sorted copy for the table. Each key is computed once per row, not per comparison (20k rows: ms, not seconds).
/// Unmeasured values sort first ascending.
// ponytail: plain `<` on lowercased strings, no numeric-aware "2 < 10"; zero-padded track numbers are fine
public func sortTracks(_ rs: [TrackResult], by key: String, ascending: Bool) -> [TrackResult] {
    func by<K: Comparable>(_ f: (TrackResult) -> K) -> [TrackResult] {
        let ks = rs.map(f)
        return rs.indices.sorted { ascending ? ks[$0] < ks[$1] : ks[$1] < ks[$0] }.map { rs[$0] }
    }
    switch key {
    case "name": return by { $0.name.lowercased() }
    case "artist": return by { ($0.artist ?? "").lowercased() + "\0" + $0.path.lowercased() }  // path keeps albums together
    case "verdict": return by { ["Fake", "Suspect", "?", "Error", "OK"].firstIndex(of: $0.verdict) ?? 5 }
    case "conf": return by(\.confidence)
    case "format": return by { fmtOf($0) }
    case "kbps": return by { $0.claimedKbps ?? -1 }
    case "cutoff": return by { $0.cutoffHz ?? -1 }
    case "est": return by { estKbps($0) ?? 0 }
    case "dr": return by { $0.dr ?? -1 }
    case "peak": return by { $0.peakDb ?? -999 }
    case "rms": return by { $0.rmsDb ?? -999 }
    case "clips": return by { $0.clipEvents ?? -1 }
    case "added": return by { $0.added ?? .distantPast }
    default: return by { $0.path.lowercased() }
    }
}

// range filters shown in the Filters sidebar: (field, label, decimals)
public let RANGES: [(field: String, label: String, decimals: Int)] = [
    ("kbps", "Bitrate (claimed) kbps", 0), ("est", "Est. source kbps", 0), ("conf", "Confidence %", 0),
    ("peak", "Peak dBFS", 1), ("rms", "RMS dBFS", 1), ("dr", "Dynamic range (DR)", 1), ("crest", "Crest dB", 1),
    ("clips", "Clip events", 0), ("clippct", "Clipped samples %", 3), ("floor", "Noise floor dBFS", 1),
    ("corr", "Stereo correlation", 3), ("width", "Width (side) %", 1), ("balance", "L/R imbalance dB", 1),
    ("cutoff", "Cutoff kHz", 1), ("rolloff", "85% rolloff kHz", 2), ("air", "Air (>16 kHz) %", 2),
    ("sr", "Sample rate kHz", 1), ("bits", "Bit depth", 0), ("dur", "Duration s", 0)]

// preset -> {field: (min, max)}, nil = open end; "lossy" ticks "Lossy files only"
public let PRESETS: [(name: String, ranges: [String: (Double?, Double?)], lossy: Bool)] = [
    ("Low bitrate source", ["est": (nil, 255)], false), ("Lossy format", [:], true),
    ("Brickwalled", ["dr": (nil, 5.9)], false), ("Clipping", ["clips": (11, nil)], false),
    ("Hot / overcompressed", ["peak": (-0.3, nil), "rms": (-9, nil)], false), ("Noisy / hiss", ["floor": (-60, nil)], false),
    ("Mono / fake stereo", ["corr": (0.995, nil)], false), ("Phase problems", ["corr": (nil, 0)], false),
    ("Channel imbalance", ["balance": (1.5, nil)], false), ("Short / preview clip", ["dur": (nil, 90)], false),
    ("Dull / no air", ["air": (nil, 0.5), "cutoff": (nil, 17)], false), ("Below CD sample rate", ["sr": (nil, 44)], false)]

public let QUERY_HELP = """
    Words search the path. Conditions (AND-ed): field op value, ops < <= > >= = !=
    Numbers: kbps est conf lossy dr peak rms crest clips clippct floor corr width balance bits dur(s) air(%) cutoff rolloff sr(kHz)
    Text (= means contains): codec verdict fmt
    e.g.  est<256 dr<7 techno
    """

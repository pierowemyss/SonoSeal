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
    r.estQuality.firstMatch(of: /\d+/).map { Int($0.output)! } ?? r.claimedKbps
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
            q.words.append(tok.lowercased())
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

public func matches(_ r: TrackResult, _ q: Query) -> Bool {
    // ponytail: AND only; split the query on '|' if OR is ever needed
    let path = r.path.lowercased()
    guard q.words.allSatisfy(path.contains) else { return false }
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

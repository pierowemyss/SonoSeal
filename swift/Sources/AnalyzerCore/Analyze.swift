// Detect fake-quality audio files and measure levels, dynamics, clipping, stereo and bandwidth.
// Port of analyze.py. Strictly read-only: files are only ever opened for reading.
import Accelerate

public let VERSION = 3  // bump when results change shape/meaning -> cached rows get re-analyzed
public let AUDIO_EXTS: Set<String> = ["mp3", "m4a", "aac", "mp4", "aif", "aiff", "aifc", "wav", "flac"]

// ponytail: heuristic thresholds, tuned on LAME/ffmpeg encodes + real house/techno masters; tune on false positives.
let NFFT = 4096
let WALL_DB = 25.0          // level drop (within ~1 kHz) across the cutoff that counts as a lowpass
let STEEP_DB = 38.0         // drop this steep = encoder lowpass. Real masters measured 26-32 dB, transcodes 39-75 dB.
let GENUINE_MIN_HZ = 20500.0  // walls at/above this: mastering/SRC filter or >=320k/V0 - indistinguishable, never "Fake"
let GENTLE_OK_HZ = 19500.0    // gentle (< STEEP_DB) lowpass at/above this = mastering filter (or V0 - same shape), "OK"
let CONTENT_DB = 50.0       // no wall: 'content' = within this many dB of the 2-8 kHz level
let SHELF_DB = 12.0         // partial drop at ~16 kHz (MP3 sfb21 shelf)
let LOSSLESS_MIN_HZ = 21000.0
let UPSAMPLE_MAX_HZ = 27000.0  // hi-res file walled below this = 44.1/48k source (resampler transition leaks to ~26k)
let SPECTRUM_BINS = 512     // stored per track for the quick spectrum plot
let CLIP_TOL = pow(10, -0.001 / 20)  // within 0.001 dB of the peak = flat-topped (also catches clipped-then-turned-down)
let CLIP_RUN = 3            // >= this many consecutive samples at the peak = one clip event
public let BANDS: [(name: String, lo: Double, hi: Double)] = [
    ("Sub", 20, 60), ("Bass", 60, 250), ("Low mids", 250, 2000), ("High mids", 2000, 6000),
    ("Highs", 6000, 16000), ("Air", 16000, 1e9)]
// (cutoff upper bound Hz, estimated source kbps). Typical LAME/AAC lowpasses.
let CUTOFF_KBPS: [(Double, Int)] = [(12000, 64), (15500, 96), (17200, 128), (18000, 160), (19000, 192),
                                    (19800, 256), (LOSSLESS_MIN_HZ, 320)]

public struct TrackResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var version = VERSION
    public var verdict: String
    public var confidence = 0
    public var reason: String
    public var estQuality = ""
    // probe
    public var codec: String?
    public var lossless: Bool?
    public var claimedKbps: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var duration: Double?
    public var artist: String?  // tag; filled outside analyze() so pre-existing cache rows pick it up without a re-scan
    public var added: Date?  // file system "date added", read fresh each scan
    // measured (nil = silent / error)
    public var cutoffHz: Double?
    public var wallDb: Double?
    public var rolloffHz: Double?
    public var bands: [String: Double]?
    public var peakDb: Double?
    public var rmsDb: Double?
    public var crestDb: Double?
    public var clipEvents: Int?
    public var clipPct: Double?
    public var correlation: Double?
    public var widthPct: Double?
    public var balanceDb: Double?
    public var dr: Double?
    public var noiseFloorDb: Double?
    public var spectrum: [Float]?  // SPECTRUM_BINS dB values, 0..Nyquist

    public init(path: String, verdict: String, reason: String) {
        self.path = path; self.verdict = verdict; self.reason = reason
    }

    public static func error(_ path: String, _ e: Error) -> TrackResult {
        TrackResult(path: path, verdict: "Error", reason: String("\(e)".suffix(300)))
    }
}

/// |rfft(x)|^2 with numpy scaling, for one fixed size.
final class RealFFT {
    let n: Int, log2n: vDSP_Length, setup: FFTSetupD, window: [Double]
    var re: [Double], im: [Double], tmp: [Double]

    init(_ n: Int) {
        self.n = n
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1)) }  // np.hanning (symmetric)
        re = .init(repeating: 0, count: n / 2); im = re; tmp = .init(repeating: 0, count: n)
    }
    deinit { vDSP_destroy_fftsetupD(setup) }

    /// Windowed power spectrum of x[start ..< start+n] added into out (n/2+1 bins).
    func accumulate(_ x: UnsafeBufferPointer<Double>, _ start: Int, into out: inout [Double]) {
        vDSP.multiply(UnsafeBufferPointer(rebasing: x[start ..< start + n]), window, result: &tmp)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                tmp.withUnsafeBytes {
                    vDSP_ctozD($0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zripD(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        // zrip output is 2x numpy's: DC in re[0], Nyquist in im[0]
        out[0] += re[0] * re[0] / 4
        out[n / 2] += im[0] * im[0] / 4
        for k in 1 ..< n / 2 { out[k] += (re[k] * re[k] + im[k] * im[k]) / 4 }
    }
}

func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-20)) }

func percentile(_ v: [Double], _ q: Double) -> Double {  // numpy 'linear'
    let s = v.sorted(), pos = q / 100 * Double(s.count - 1), i = Int(pos)
    return i + 1 < s.count ? s[i] + (s[i + 1] - s[i]) * (pos - Double(i)) : s[i]
}

struct Stats {
    var peakDb = 0.0, rmsDb = 0.0, crestDb = 0.0, clipEvents = 0, clipPct = 0.0, correlation = 1.0
    var widthPct = 0.0, balanceDb = 0.0, dr: Double?, noiseFloorDb = -140.0
}

/// One streaming pass over the full track (stereo). Returns (average power spectrum, stats), nil if too short/silent.
func measure(_ url: URL, _ sr: Int) throws -> ([Double], Stats)? {
    let block = 3 * sr  // DR blocks
    let fft = RealFFT(NFFT)
    var power = [Double](repeating: 0, count: NFFT / 2 + 1), frames = 0
    var n = 0, peak = 0.0, ssL = 0.0, ssR = 0.0, lr = 0.0
    var blkRms: [[Double]] = [[], []], blkPeak: [[Double]] = [[], []], winRms: [Double] = []
    var clips: [(peak: Double, events: Int, samples: Int)] = []
    let w = max(sr / 20, 1)  // noise floor: 50 ms window RMS
    var m = [Double](repeating: 0, count: block + NFFT), carry = 0  // carry: mid samples not yet in an FFT frame

    // One chunk = one DR block: per-chunk sums double as block stats, and ~1 MB/channel stays in L2 across passes.
    try decode(url, chunk: block) { l, r in
        let len = l.count
        n += len
        let pkL = vDSP.maximumMagnitude(l), pkR = vDSP.maximumMagnitude(r), pk = max(pkL, pkR)
        lr += vDSP.dot(l, r)
        var sL = 0.0, sR = 0.0  // channel sums built from the window sums: one pass serves both
        for i in 0 ..< len / w {
            let a = vDSP.sumOfSquares(l[i * w ..< (i + 1) * w]), b = vDSP.sumOfSquares(r[i * w ..< (i + 1) * w])
            sL += a; sR += b
            winRms.append(sqrt((a + b) / Double(2 * w)))
        }
        sL += vDSP.sumOfSquares(l[len / w * w ..< len]); sR += vDSP.sumOfSquares(r[len / w * w ..< len])
        ssL += sL; ssR += sR
        // spectrum of the mid (mono) signal
        m.withUnsafeMutableBufferPointer { mp in
            vDSP_vasmD(l, 1, r, 1, [0.5], mp.baseAddress! + carry, 1, vDSP_Length(len))  // (l + r) * 0.5
            let nf = (carry + len) / NFFT
            for i in 0 ..< nf { fft.accumulate(UnsafeBufferPointer(mp), i * NFFT, into: &power) }
            frames += nf
            carry = (carry + len) % NFFT
            // frames restart every 30 s (the Python reference's chunking), so spectra match it exactly
            if n % (10 * block) == 0 { carry = 0 }
            mp.baseAddress!.update(from: mp.baseAddress! + nf * NFFT, count: carry)
        }
        // DR: 3 s blocks, per channel (TT DR meter style: RMS*sqrt(2)); a short tail chunk isn't a block
        if len == block {
            blkRms[0].append(sqrt(2 * sL / Double(len))); blkRms[1].append(sqrt(2 * sR / Double(len)))
            blkPeak[0].append(pkL); blkPeak[1].append(pkR)
        }
        // clipping: runs of consecutive samples at this chunk's peak, per channel.
        // A chunk below the running peak can never be kept (the final peak only grows), so skip the scan.
        if pk < peak * CLIP_TOL { return }
        peak = max(peak, pk)
        let thr = pk * CLIP_TOL
        var ev = 0, smp = 0
        for x in [l, r] {
            x.withUnsafeBufferPointer { x in
                var run = 0
                for v in x {
                    if abs(v) >= thr { run += 1; continue }
                    if run >= CLIP_RUN { ev += 1; smp += run }
                    run = 0
                }
                if run >= CLIP_RUN { ev += 1; smp += run }
            }
        }
        clips.append((pk, ev, smp))
    }
    if n < NFFT * 4 || peak < 1e-4 { return nil }

    // ponytail: per-chunk peak plateaus, kept only for chunks reaching the track peak; exact needs a 2nd pass
    let atPeak = clips.filter { $0.peak >= peak * CLIP_TOL }
    let rms = sqrt((ssL + ssR) / Double(2 * n))
    var st = Stats()
    st.peakDb = db(peak * peak); st.rmsDb = db(rms * rms); st.crestDb = st.peakDb - st.rmsDb
    st.clipEvents = atPeak.reduce(0) { $0 + $1.events }
    st.clipPct = 100 * Double(atPeak.reduce(0) { $0 + $1.samples }) / Double(2 * n)
    st.correlation = ssL > 0 && ssR > 0 ? lr / sqrt(ssL * ssR) : 1
    // sum((l±r)/2)^2 = (ssL + ssR ± 2·lr) / 4, so mid + side = (ssL + ssR) / 2
    let side = (ssL + ssR - 2 * lr) / 4, both = (ssL + ssR) / 2
    st.widthPct = both > 0 ? 100 * side / both : 0  // side share of energy
    st.balanceDb = db(ssL) - db(ssR)                                // + = left louder
    if !blkRms[0].isEmpty {  // DR = mean over channels of 20log(2nd-highest block peak / RMS of loudest 20% blocks)
        let top = max(1, blkRms[0].count / 5)
        let drs = (0 ..< 2).map { c -> Double in
            let p = blkPeak[c].sorted(), r = blkRms[c].sorted().suffix(top)
            return 20 * log10(p[p.count > 1 ? p.count - 2 : 0] / sqrt(vDSP.meanSquare(Array(r))))
        }
        st.dr = max(0, (drs[0] + drs[1]) / 2)
    }
    let wr = winRms.filter { $0 > 1e-7 }  // ignore digital silence (lead-in/out)
    // ponytail: noise floor = 1st percentile of 50 ms window RMS; true floor needs gap/fade detection
    if !wr.isEmpty { st.noiseFloorDb = db(pow(percentile(wr, 1), 2)) }
    return (power.map { $0 / Double(max(frames, 1)) }, st)
}

/// 85% rolloff + energy share per band, from the linear average power spectrum.
func spectralStats(_ p: [Double], _ sr: Int) -> (Double, [String: Double]) {
    let f = (0 ..< p.count).map { Double($0) * Double(sr) / Double(NFFT) }
    let p = zip(p, f).map { $1 < 20 ? 0 : $0 }  // ignore DC/infrasonic
    var c = p, acc = 0.0
    for i in c.indices { acc += c[i]; c[i] = acc }
    var bands: [String: Double] = [:]
    for b in BANDS {
        bands[b.name] = 100 * zip(p, f).reduce(0) { $1.1 >= b.lo && $1.1 < b.hi ? $0 + $1.0 : $0 } / acc
    }
    return (f[c.firstIndex { $0 >= 0.85 * acc } ?? c.count - 1], bands)
}

func toDb(_ p: [Double]) -> [Double] {
    let d = p.map { 10 * log10($0 + 1e-20) }
    let sm = d.indices.map { i in  // np.convolve(d, ones(5)/5, 'same'): light smoothing, zero-padded edges
        d[max(0, i - 2) ... min(d.count - 1, i + 2)].reduce(0, +) / 5
    }
    let mx = sm.max() ?? 0
    return sm.map { max($0 - mx, -150) }
}

func median(_ v: ArraySlice<Double>) -> Double {
    let s = v.sorted(), m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

/// Returns (cutoff_hz, wall_drop_db, shelf_db).
/// Wall = big drop at f that stays down all the way to Nyquist. Drop size ~ steepness (fixed 1 kHz windows).
/// Not depth below the wall: clipped 16-bit transcodes of loud masters fill it with distortion noise.
func findCutoff(_ db: [Double], _ sr: Int) -> (Double, Double, Double) {
    let hz = Double(sr) / Double(NFFT)
    let k = { (f: Double) in Int(f / hz) }
    let nyq = db.count - 1
    let mean = { (s: ArraySlice<Double>) in s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count) }
    // sufMax[j] = max(db[j ... nyq-k(500)]): the "stays down to Nyquist" check, precomputed
    let end = nyq - k(500)
    var sufMax = [Double](repeating: -.infinity, count: db.count + 1)
    if end >= 0 { for j in stride(from: min(end, nyq), through: 0, by: -1) { sufMax[j] = max(db[j], sufMax[j + 1]) } }
    var bestF = 0, bestDrop = 0.0
    if k(8000) < nyq - k(1000) {
        for i in k(8000) ..< nyq - k(1000) {
            let below = mean(db[i - k(1000) ..< i - k(200)])
            let above = mean(db[i + k(200) ..< i + k(1000)])
            let drop = below - above
            if drop > bestDrop && sufMax[i + k(200)] < below - drop / 2 { bestF = i; bestDrop = drop }
        }
    }
    var cutoff: Double
    if bestDrop >= WALL_DB {
        cutoff = Double(bestF) * hz
    } else {  // no wall: highest freq clearly above the floor (natural roll-off or full band)
        let ref = median(db[k(2000) ..< min(k(8000), db.count)])
        cutoff = Double(db.lastIndex { $0 > ref - CONTENT_DB } ?? 0) * hz
        bestDrop = 0
    }
    var shelf = 0.0
    if sr >= 40000 { shelf = mean(db[k(14500) ..< k(15800)]) - mean(db[k(16200) ..< k(17500)]) }
    return (cutoff, bestDrop, shelf)
}

func estKbps(_ cutoff: Double) -> Int? {
    CUTOFF_KBPS.first { cutoff < $0.0 }?.1  // nil = lossless-grade bandwidth
}

/// 24-bit file whose low 8 bits (of 24) are always zero -> 16-bit padded.
func isPadded(_ url: URL, _ sr: Int, start: Double, dur: Double) throws -> Bool {
    var nz = 0, padded = true
    try decode(url, chunk: 1 << 16, start: start, frames: Int(dur * Double(sr)), int32: true) { l, r in
        for v in l + r where v != 0 {
            if Int32(v) & 0xFFFF != 0 { padded = false }  // Int32 is left-justified: 24-bit low byte = bits 8..15
            nz += 1
        }
    }
    return padded && nz > 1000
}

func g(_ x: Double) -> String { String(format: "%g", x) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f0(_ x: Double) -> String { String(format: "%.0f", x) }

/// Returns (verdict, confidence%, est_quality, reason).
func verdict(_ info: Info, _ cutoff: Double, _ drop: Double, _ shelf: Double, _ padded: Bool) -> (String, Int, String, String) {
    let wall = drop >= WALL_DB
    let encoder = drop >= STEEP_DB && cutoff < GENUINE_MIN_HZ  // steep wall below 20.5 kHz = lossy encoder lowpass
    let est = encoder ? estKbps(cutoff) : nil
    let conf = encoder ? Int(min(max(60 + (drop - STEEP_DB) * 1.5, 60), 99)) : 0
    let k = f1(cutoff / 1000), d = f0(drop)
    if info.lossless {
        if let est {
            return ("Fake", conf, "~\(est) kbps", "Lossless file, brick-wall cutoff at \(k) kHz (\(d) dB drop) -> ~\(est) kbps lossy source")
        }
        if info.sampleRate > 48000 && wall && cutoff < UPSAMPLE_MAX_HZ {
            return ("Fake", 80, "upsampled", "\(g(Double(info.sampleRate) / 1000)) kHz file with no content above \(k) kHz -> upsampled")
        }
        if padded { return ("Fake", 95, "16-bit", "24-bit file whose low 8 bits are always zero -> padded 16-bit") }
        if wall && cutoff < GENTLE_OK_HZ {
            return ("Suspect", 45, "?", "Gentle lowpass at \(k) kHz (\(d) dB drop): production filter, or a transcode")
        }
        if shelf >= SHELF_DB { return ("Suspect", 50, "MP3?", "\(f0(shelf)) dB shelf at 16 kHz (MP3 sfb21 pattern)") }
        if cutoff < 16000 { return ("Suspect", 40, "?", "Gradual roll-off around \(k) kHz (old master/vinyl, or lossy source)") }
        if wall {
            return ("OK", 75, "lossless?", "Gentle lowpass at \(k) kHz (\(d) dB drop): typical mastering/sample-rate-conversion filter (a V0 source would look the same)")
        }
        return ("OK", 90, "lossless", "Content up to \(k) kHz")
    }
    let claimed = info.claimedKbps
    if let est, claimed > 0, Double(est) <= Double(claimed) / 2 {
        return ("Fake", conf, "~\(est) kbps", "Claims \(claimed) kbps, cutoff \(k) kHz -> ~\(est) kbps source")
    }
    if let est, claimed > 0, Double(est) < Double(claimed) * 0.75 {
        return ("Suspect", min(conf, 70), "~\(est) kbps", "Claims \(claimed) kbps, cutoff \(k) kHz suggests ~\(est) kbps")
    }
    if !wall && cutoff < 15000 && claimed >= 192 {
        return ("Suspect", 40, "?", "Gradual roll-off around \(k) kHz despite \(claimed) kbps")
    }
    return ("OK", 85, "\(claimed) kbps", "Cutoff \(k) kHz consistent with \(claimed) kbps")
}

public func analyze(_ url: URL) throws -> TrackResult {
    let info = try probe(url)
    var r = TrackResult(path: url.path, verdict: "?", reason: "Too short or silent to analyze")
    r.codec = info.codec; r.lossless = info.lossless; r.claimedKbps = info.claimedKbps
    r.sampleRate = info.sampleRate; r.bitDepth = info.bitDepth; r.channels = info.channels; r.duration = info.duration
    r.cutoffHz = 0
    guard let (p, st) = try measure(url, info.sampleRate) else { return r }
    let d = toDb(p)
    let (cutoff, drop, shelf) = findCutoff(d, info.sampleRate)
    let padded = try info.lossless && info.bitDepth == 24 && isPadded(url, info.sampleRate, start: info.duration / 2, dur: 10)
    (r.verdict, r.confidence, r.estQuality, r.reason) = verdict(info, cutoff, drop, shelf, padded)
    let (rolloff, bands) = spectralStats(p, info.sampleRate)
    let per = d.count / SPECTRUM_BINS
    r.spectrum = (0 ..< SPECTRUM_BINS).map { i in Float(d[i * per ..< (i + 1) * per].reduce(0, +) / Double(per)) }
    r.cutoffHz = cutoff; r.wallDb = drop; r.rolloffHz = rolloff; r.bands = bands
    r.peakDb = st.peakDb; r.rmsDb = st.rmsDb; r.crestDb = st.crestDb; r.clipEvents = st.clipEvents; r.clipPct = st.clipPct
    r.correlation = st.correlation; r.widthPct = st.widthPct; r.balanceDb = st.balanceDb; r.dr = st.dr
    r.noiseFloorDb = st.noiseFloorDb
    return r
}

public struct Spectrogram: Sendable {
    public var db: [Float]  // columns x bins, row-major, 0 = loudest, floor -120
    public var columns: Int, bins: Int, sampleRate: Int, duration: Double
}

/// Full-track spectrogram for the viewer. Streams the file, so memory is independent of track length.
public func spectrogram(_ url: URL, columns: Int = 1500, nfft: Int = 2048) throws -> Spectrogram {
    let info = try probe(url)
    let sr = info.sampleRate, total = Int(info.duration * Double(sr))
    guard total >= nfft else { throw CocoaError(.fileReadCorruptFile) }
    let starts = (0 ..< columns).map { Int(Double(total - nfft) * Double($0) / Double(columns - 1)) }
    let fft = RealFFT(nfft), bins = nfft / 2 + 1
    var out = [Float](), col = 0, buf: [Double] = [], bufStart = 0
    out.reserveCapacity(columns * bins)
    try decode(url, chunk: 1 << 18) { l, r in
        buf += vDSP.multiply(0.5, vDSP.add(l, r))  // mono
        buf.withUnsafeBufferPointer { bp in
            while col < columns && starts[col] + nfft <= bufStart + bp.count {
                var p = [Double](repeating: 0, count: bins)
                fft.accumulate(bp, starts[col] - bufStart, into: &p)
                out += p.map { Float(10 * log10($0 + 1e-20)) }  // = 20log10|X|
                col += 1
            }
        }
        let drop = min(col < columns ? starts[col] - bufStart : buf.count, buf.count)
        buf.removeFirst(drop); bufStart += drop
    }
    while col < columns { out += [Float](repeating: -200, count: bins); col += 1 }  // short read: pad
    let mx = out.max() ?? 0
    return Spectrogram(db: out.map { max($0 - mx, -120) }, columns: columns, bins: bins,
                       sampleRate: sr, duration: Double(total) / Double(sr))
}

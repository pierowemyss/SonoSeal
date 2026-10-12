// Port of test_analyze.py + cache.py self-test + Python parity. Run: swift test -c release
import AnalyzerCore
import Foundation
import Testing

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()  // repo root
let samples = root.appending(path: "samples")
let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.fileExists)
let D = FileManager.default.temporaryDirectory.appending(path: "mla-tests-\(ProcessInfo.processInfo.processIdentifier)")

@discardableResult
func run(_ exe: String, _ args: [String]) throws -> Data {
    let p = Process(), out = Pipe()
    p.executableURL = URL(filePath: exe)
    p.arguments = args
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    return data
}

func ff(_ args: [String]) throws { try run(ffmpeg!, ["-v", "error", "-y"] + args) }

func src(_ name: String, _ extra: [String] = []) throws -> URL {
    let out = D.appending(path: name)
    // pink noise: music-like spectrum that still reaches Nyquist
    try ff(["-f", "lavfi", "-i", "anoisesrc=d=40:c=pink:r=44100:a=0.3", "-ac", "2"] + extra + [out.path])
    return out
}

func enc(_ inp: URL, _ name: String, _ args: String...) throws -> URL {
    let out = D.appending(path: name)
    try ff(["-i", inp.path] + args + [out.path])
    return out
}

func check(_ u: URL, _ want: String, _ est: String? = nil) throws {
    let r = try analyze(u)
    print(u.lastPathComponent, r.verdict, r.confidence, r.reason)
    #expect(r.verdict == want, "\(u.lastPathComponent): \(r.reason)")
    if let est { #expect(r.estQuality.contains(est), "\(u.lastPathComponent): est \(r.estQuality)") }
}

@Test(.enabled(if: ffmpeg != nil)) func syntheticFixtures() throws {
    try FileManager.default.createDirectory(at: D, withIntermediateDirectories: true)
    let wav = try src("real.wav")
    try check(enc(wav, "real.flac"), "OK")
    try check(enc(wav, "real.m4a", "-c:a", "alac"), "OK")
    let mp3 = try enc(wav, "128.mp3", "-b:a", "128k")
    try check(mp3, "OK")
    try check(enc(mp3, "fake128.flac"), "Fake", "128")
    try check(enc(mp3, "fake128.aiff"), "Fake", "128")
    try check(enc(mp3, "fake320.mp3", "-b:a", "320k"), "Fake", "128")
    try check(enc(wav, "320.mp3", "-b:a", "320k"), "OK")
    try check(enc(wav, "256.m4a", "-c:a", "aac", "-b:a", "256k"), "OK")
    try check(enc(wav, "up96.flac", "-ar", "96000"), "Fake", "upsampled")
    try check(enc(wav, "pad24.flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"), "Fake", "16-bit")
    try check(src("real24.flac", ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]), "OK")

    // levels / clipping / stereo
    let sine = D.appending(path: "sine.flac")
    try ff(["-f", "lavfi", "-i", "sine=f=1000:d=20", "-ac", "2", sine.path])
    var r = try analyze(sine)  // sine: crest = 3.01 dB, identical channels
    #expect(abs(r.crestDb! - 3.01) < 0.05 && abs(r.rmsDb! - (r.peakDb! - 3.01)) < 0.05)
    #expect(r.correlation! > 0.999 && r.widthPct! < 0.1 && r.clipEvents == 0)
    #expect(abs(r.rolloffHz! - 1000) < 50 && r.bands!["Low mids"]! > 99)
    r = try analyze(enc(wav, "clipped.flac", "-af", "volume=30dB"))  // hard clips at full scale
    #expect(r.clipEvents! > 100)
    #expect(try analyze(wav).clipEvents == 0)

    // spectrogram streams the whole file
    let s = try spectrogram(sine)
    #expect(s.db.count == s.columns * s.bins && s.db.max() == 0 && abs(s.duration - 20) < 0.1)
}

// real tracks (Tidal, CD rips, web) incl. ~20.4-20.7 kHz mastering lowpasses must not be flagged
@Test func sampleTracks() throws {
    for u in audioFiles([samples]) {
        try check(u, u.path.contains("/Fakes/") ? "Fake" : "OK")
    }
}

// Same verdicts and near-identical measurements as the Python reference (skipped without python3 + numpy)
@Test(.enabled(if: (try? run("/usr/bin/env", ["python3", "-c", "import numpy"])) != nil))
func pythonParity() throws {
    let files = audioFiles([samples]).map(\.path)
    let script = """
        import json, sys; sys.path.insert(0, sys.argv[1]); import analyze
        print(json.dumps([{k: v for k, v in analyze.analyze(p).items() if k != 'spectrum'} for p in sys.argv[2:]]))
        """
    let py = try JSONSerialization.jsonObject(with: run("/usr/bin/env", ["python3", "-c", script, root.appending(path: "python").path] + files))
        as! [[String: Any]]
    for (p, want) in zip(files, py) {
        let r = try analyze(URL(filePath: p)), name = URL(filePath: p).lastPathComponent
        #expect(r.verdict == want["verdict"] as? String, "\(name)")
        #expect(abs(r.cutoffHz! - (want["cutoff_hz"] as! Double)) <= 250, "\(name) cutoff")
        #expect(abs(r.dr! - (want["dr"] as! Double)) <= 0.5, "\(name) dr")
        #expect(abs(r.peakDb! - (want["peak_db"] as! Double)) <= 0.1, "\(name) peak")
        #expect(abs(r.rmsDb! - (want["rms_db"] as! Double)) <= 0.1, "\(name) rms")
    }
}

@Test func queryFilters() {
    let q = { (text: String, r: TrackResult) in matches(r, parseQuery(text)) }
    var mp3 = TrackResult(path: "/m/Techno/a.flac", verdict: "Fake", reason: "")
    mp3.codec = "flac"; mp3.lossless = true; mp3.claimedKbps = 900; mp3.estQuality = "~128 kbps"
    mp3.dr = 5.2; mp3.peakDb = -0.1; mp3.clipEvents = 40; mp3.balanceDb = -2.0
    let err = TrackResult(path: "/m/b.mp3", verdict: "Error", reason: "")
    #expect(q("est<256 dr<6 clips>10", mp3) && !q("est>=256", mp3))
    #expect(q("kbps>320 est=128", mp3) && q("lossy=0 balance>1.5", mp3))
    #expect(q("codec=fla verdict!=ok techno", mp3) && !q("codec!=flac", mp3) && !q("house", mp3))
    #expect(!q("dr<20", err) && q("b.mp3", err))
}

@Test func cacheRoundTrip() async {
    let c = Cache(path: ":memory:")
    var r = TrackResult(path: "/a.flac", verdict: "Fake", reason: "x")
    r.spectrum = (0 ..< 512).map { -100 + Float($0) * 100 / 511 }
    await c.put(r, mtime: 1, size: 10)
    let got = await c.get("/a.flac", mtime: 1, size: 10)
    #expect(got?.verdict == "Fake" && abs(got!.spectrum!.last!) < 0.1)
    #expect(await c.get("/a.flac", mtime: 2, size: 10) == nil)  // changed mtime -> miss
}

@Test func playlistsAndCSV() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mla-pl-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "#EXTM3U\n#EXTINF:1,x\nsub/a.flac\n/abs/b.mp3\n\n".write(to: dir.appending(path: "p.m3u8"), atomically: true, encoding: .utf8)
    #expect(try readPlaylist(dir.appending(path: "p.m3u8")).map(\.path) == [dir.appending(path: "sub/a.flac").path, "/abs/b.mp3"])
    let xml = """
        <DJ_PLAYLISTS><COLLECTION><TRACK TrackID="1" Location="file://localhost/Music/A%20B.flac"/></COLLECTION>
        <PLAYLISTS><NODE><TRACK Key="1"/></NODE></PLAYLISTS></DJ_PLAYLISTS>
        """
    try xml.write(to: dir.appending(path: "rb.xml"), atomically: true, encoding: .utf8)
    #expect(try readPlaylist(dir.appending(path: "rb.xml")).map(\.path) == ["/Music/A B.flac"])
    let line = csv([TrackResult(path: "/a,b.flac", verdict: "OK", reason: "say \"hi\"")]).split(separator: "\n")[1]
    #expect(line.hasPrefix("\"/a,b.flac\",OK,0,") && line.hasSuffix("\"say \"\"hi\"\"\""))
}

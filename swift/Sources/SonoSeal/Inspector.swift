import AnalyzerCore
import Charts
import SwiftUI

struct Inspector: View {
    var model: Model

    var body: some View {
        if let r = model.selected {
            Details(r: r).id(r.path)
        } else {
            ContentUnavailableView(model.selection.count > 1 ? "\(model.selection.count) tracks selected" : "No track selected",
                                   systemImage: "waveform",
                                   description: Text(model.selection.count > 1 ? "Right-click to reveal, tag or trash them."
                                                                                 : "Select a track to see its spectrum and measurements."))
        }
    }
}

struct Details: View {
    let r: TrackResult
    @State private var spec: Result<(Spectrogram, CGImage?), Error>?
    var color: Color { COLORS[r.verdict] ?? .gray }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let s = r.spectrum, let sr = r.sampleRate { SpectrumChart(spectrum: s, sampleRate: sr, r: r, color: color) }
                spectrogramView
                metrics
            }
            .padding()
        }
        .task {  // debounced so arrowing through the list doesn't queue decodes
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let url = URL(fileURLWithPath: r.path)
            // image built off the main thread too: 1500 x 1024 pixels
            spec = await Task.detached(priority: .userInitiated) { Result { let s = try spectrogram(url); return (s, s.image()) } }.value
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.verdict.uppercased()).font(.largeTitle.weight(.heavy)).foregroundStyle(color)
                Text("\(r.confidence)% confidence").foregroundStyle(.secondary)
                Spacer()
                if let c = r.cutoffHz, c > 0 {
                    Text("cutoff \(c / 1000, specifier: "%.1f") kHz").font(.headline.monospacedDigit())
                }
            }
            Text(r.reason).font(.callout)
            Text(r.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
        .padding(14)
        .glassEffect(.regular.tint(color.opacity(0.18)), in: .rect(cornerRadius: 18))
    }

    @ViewBuilder var spectrogramView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spectrogram (full track)").font(.headline)
            switch spec {
            case nil: ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            case let .failure(e): Text("Spectrogram failed: \(e.localizedDescription)").foregroundStyle(.secondary)
            case let .success((s, image)): SpectrogramChart(s: s, image: image, cutoff: r.cutoffHz, color: color)
            }
            Text("dotted: 16 / 19 / 20 kHz · dashed: detected cutoff").font(.caption2).foregroundStyle(.secondary)
        }
    }

    var metrics: some View {
        let dur = r.duration ?? 0
        let file: [(String, String)] = [
            ("Codec", r.codec ?? "?"), ("Bitrate", "\(r.claimedKbps ?? 0) kbps"),
            ("Format", "\(String(format: "%g", Double(r.sampleRate ?? 0) / 1000)) kHz / \(r.bitDepth.flatMap { $0 > 0 ? "\($0)" : nil } ?? "-") bit"),
            ("Duration", "\(Int(dur) / 60):\(String(format: "%02d", Int(dur) % 60))"), ("Est. source", r.estQuality)]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)], alignment: .leading, spacing: 14) {
            MetricSection("File", file)
            if let dr = r.dr, let peak = r.peakDb, let rms = r.rmsDb {
                MetricSection("Level & dynamics", [
                    ("Peak", f(peak, "dBFS")), ("RMS", f(rms, "dBFS")), ("Crest factor", f(r.crestDb, "dB")),
                    ("Noise floor", f(r.noiseFloorDb, "dBFS")), ("Dynamic range", "DR\(Int(dr.rounded())) · \(drNote(dr))")])
                MetricSection("Clipping", [("Events", r.clipEvents.map { $0 == 0 ? "none" : "\($0)" } ?? ""),
                                     ("Samples", String(format: "%.3f %%", r.clipPct ?? 0))])
                MetricSection("Stereo", [
                    ("Correlation", String(format: "%.2f · ", r.correlation ?? 0) + corrNote(r.correlation ?? 0)),
                    ("Width (side)", String(format: "%.1f %%", r.widthPct ?? 0)),
                    ("Balance L/R", String(format: "%+.1f dB", r.balanceDb ?? 0))])
                bandwidth
            }
        }
    }

    var bandwidth: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bandwidth usage").font(.headline)
            Text("Cutoff \(String(format: "%.1f kHz · %.0f dB drop", (r.cutoffHz ?? 0) / 1000, r.wallDb ?? 0))  ·  85% rolloff \(String(format: "%.2f kHz", (r.rolloffHz ?? 0) / 1000))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(BANDS, id: \.name) { b in
                let v = r.bands?[b.name] ?? 0
                HStack {
                    Text(b.name).frame(width: 70, alignment: .leading)
                    ProgressView(value: min(v, 100), total: 100)
                    Text(String(format: "%.1f %%", v)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .font(.caption)
            }
        }
    }

    func f(_ v: Double?, _ unit: String) -> String { v.map { String(format: "%.1f \(unit)", $0) } ?? "" }
}

func drNote(_ dr: Double) -> String { dr < 6 ? "crushed" : dr < 9 ? "loud / club master" : dr < 13 ? "moderate" : "dynamic" }

func corrNote(_ c: Double) -> String {
    c > 0.995 ? "mono" : c > 0.9 ? "narrow" : c > 0.3 ? "normal" : c >= 0 ? "very wide" : "out of phase!"
}

struct MetricSection: View {
    let title: String, rows: [(String, String)]
    init(_ title: String, _ rows: [(String, String)]) { self.title = title; self.rows = rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        Text(v).fontWeight(.medium).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpectrumChart: View {
    let spectrum: [Float], sampleRate: Int, r: TrackResult, color: Color

    var body: some View {
        let nyq = Double(sampleRate) / 2000, n = spectrum.count
        VStack(alignment: .leading, spacing: 4) {
            Text("Average spectrum (full track)").font(.headline)
            Chart {
                let pts = spectrum.indices.map { SIMD2(nyq * Double($0) / Double(n - 1), Double(spectrum[$0])) }  // (kHz, dB)
                LinePlot(pts, x: .value("kHz", \.x), y: .value("dB", \.y))
                    .foregroundStyle(Color.accentColor)  // one vectorized mark, not 512 LineMarks
                if let c = r.cutoffHz, c > 0 {
                    RuleMark(x: .value("cutoff", c / 1000))
                        .foregroundStyle(color).lineStyle(.init(lineWidth: 1.5, dash: [5, 3]))
                        .annotation(position: .top, alignment: .trailing) { Text("cutoff").font(.caption2).foregroundStyle(color) }
                }
                if let ro = r.rolloffHz, ro > 0 {
                    RuleMark(x: .value("rolloff", ro / 1000))
                        .foregroundStyle(.gray).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("85% rolloff").font(.caption2).foregroundStyle(.gray) }
                }
            }
            .chartXScale(domain: 0 ... nyq)
            .chartYScale(domain: -130 ... 0)
            .chartXAxisLabel("kHz")
            .chartYAxisLabel("dB")
            .frame(height: 200)
        }
    }
}

struct SpectrogramChart: View {
    let s: Spectrogram, image: CGImage?, cutoff: Double?, color: Color

    var body: some View {
        let nyq = Double(s.sampleRate) / 2000
        Chart {
            ForEach([16.0, 19.0, 20.0].filter { $0 < nyq }, id: \.self) { k in
                RuleMark(y: .value("kHz", k)).foregroundStyle(.white.opacity(0.4)).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
            }
            if let c = cutoff, c > 0 {
                RuleMark(y: .value("cutoff", c / 1000)).foregroundStyle(color).lineStyle(.init(lineWidth: 2, dash: [6, 3]))
            }
        }
        .chartXScale(domain: 0 ... s.duration)
        .chartYScale(domain: 0 ... nyq)
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("kHz")
        .chartPlotStyle { plot in
            plot.background {
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.medium) }
            }
        }
        .frame(height: 260)
    }
}

// inferno colormap stops (matplotlib), interpolated
let INFERNO: [(Double, Double, Double)] = [
    (0, 0, 4), (22, 11, 57), (66, 10, 104), (106, 23, 110), (147, 38, 103), (188, 55, 84),
    (221, 81, 58), (243, 118, 27), (252, 165, 10), (246, 215, 70), (252, 255, 164)]

extension Spectrogram {
    /// dB image -> CGImage, time left to right, low frequencies at the bottom.
    func image() -> CGImage? {
        let lut: [UInt32] = (0 ..< 256).map { i in
            let t = Double(i) / 255 * Double(INFERNO.count - 1), k = min(Int(t), INFERNO.count - 2), f = t - Double(k)
            let (a, b) = (INFERNO[k], INFERNO[k + 1])
            let c = { (x: Double, y: Double) in UInt32((x + (y - x) * f).rounded()) }
            return 0xFF00_0000 | c(a.2, b.2) << 16 | c(a.1, b.1) << 8 | c(a.0, b.0)  // RGBA little-endian
        }
        var px = [UInt32](repeating: 0, count: columns * bins)
        for x in 0 ..< columns {
            for y in 0 ..< bins {
                let v = db[x * bins + y]  // -120...0
                px[(bins - 1 - y) * columns + x] = lut[Int(min(255, max(0, (v + 120) / 120 * 255)))]
            }
        }
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: columns, height: bins, bitsPerComponent: 8, bytesPerRow: columns * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

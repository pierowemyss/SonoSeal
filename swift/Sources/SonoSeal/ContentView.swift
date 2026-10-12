import AnalyzerCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: Model
    @State private var showHelp = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            // fixed min sizes: otherwise each column's min tracks its content (status bar, empty-state overlay),
            // and a big filter change resizes the split view mid-layout -> AppKit "too many update constraints" abort
            table
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                .inspector(isPresented: $model.showInspector) {
                    Inspector(model: model)
                        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                        .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
                }
        }
        .navigationTitle(model.root?.lastPathComponent ?? "SonoSeal")
        .navigationSubtitle(model.root?.path ?? (model.sources.isEmpty ? "" : "\(model.total) tracks"))
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search path, or est<256 dr<7…")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in model.drop(urls) }
    }

    // MARK: table
    var table: some View {
        Table(of: TrackResult.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            Group {
                TableColumn("Name", value: \TrackResult.name) { r in Text(r.name).help(r.reason) }
                    .width(min: 120, ideal: 280)
                TableColumn("Artist", value: \TrackResult.sArtist) { r in Text(r.sArtist) }.width(min: 60, ideal: 140)
                TableColumn("Verdict", value: \TrackResult.verdictRank) { r in VerdictBadge(verdict: r.verdict) }
                    .width(ideal: 76)
                TableColumn("Conf %", value: \TrackResult.confidence) { r in Text("\(r.confidence)").monospacedDigit() }
                    .width(ideal: 52)
                TableColumn("Format", value: \TrackResult.format).width(ideal: 100)
                TableColumn("kbps", value: \TrackResult.sKbps) { r in Text(r.claimedKbps.map(String.init) ?? "").monospacedDigit() }
                    .width(ideal: 48)
            }
            Group {
                TableColumn("Cutoff kHz", value: \TrackResult.sCutoff) { r in num(r.cutoffHz.map { $0 / 1000 }) }.width(ideal: 66)
                TableColumn("Est. source", value: \TrackResult.sEst) { r in Text(r.estQuality) }.width(ideal: 80)
                TableColumn("DR", value: \TrackResult.sDr) { r in num(r.dr, "%.0f") }.width(ideal: 34)
                TableColumn("Peak", value: \TrackResult.sPeak) { r in num(r.peakDb) }.width(ideal: 44)
                TableColumn("RMS", value: \TrackResult.sRms) { r in num(r.rmsDb) }.width(ideal: 44)
                TableColumn("Clips", value: \TrackResult.sClips) { r in Text(r.clipEvents.map(String.init) ?? "").monospacedDigit() }
                    .width(ideal: 44)
                TableColumn("Added", value: \TrackResult.sAdded) { r in
                    Text(r.added?.formatted(date: .abbreviated, time: .omitted) ?? "").monospacedDigit()
                }
                .width(ideal: 86)
            }
        } rows: {
            ForEach(model.filtered) { TableRow($0) }
        }
        // fresh table per sort order: diffing a full reorder of thousands of rows freezes the app.
        // ponytail: resets dragged column widths on re-sort; persist them via columnCustomization if that bugs anyone
        .id(model.sortOrder)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(ids) }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPaths(ids) }
            Divider()
            Button("Apply Finder Tags", systemImage: "tag") { model.tag(ids) }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.trash(ids) }
        } primaryAction: { _ in
            model.showInspector = true
        }
        .onDeleteCommand { model.trash() }
        .overlay {
            if model.results.isEmpty && !model.scanning {
                ContentUnavailableView {
                    Label("Drop music here", systemImage: "waveform.badge.magnifyingglass")
                } description: {
                    Text("Drop a folder, an album or single tracks, or choose a folder to scan. "
                         + "FLAC, WAV, AIFF, ALAC, MP3 and AAC are analyzed on this Mac — nothing is uploaded or modified.")
                } actions: {
                    Button("Add Folder…") { model.chooseFolder() }.buttonStyle(.glassProminent)
                }
            } else if model.filtered.isEmpty && !model.results.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
    }

    func num(_ v: Double?, _ f: String = "%.1f") -> Text {
        Text(v.map { String(format: f, $0) } ?? "").monospacedDigit()
    }

    // MARK: toolbar
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Add Folder", systemImage: "folder.badge.plus") { model.chooseFolder() }
                .help("Add a music folder to scan")
            if model.scanning {
                Button("Stop", systemImage: "stop.fill") { model.stop() }.help("Stop scanning")
            } else {
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                    .disabled(model.sources.isEmpty).help("Scan again (unchanged files come from the cache)")
            }
        }
        ToolbarItem {
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                ForEach(SortChoice.allCases) { c in
                    Toggle(c.rawValue, isOn: Binding(get: { model.sortOrder == c.order }, set: { _ in model.sortOrder = c.order }))
                }
            }
            .help("Sort tracks (or click a column header)")
        }
        ToolbarItem {
            Button("Query help", systemImage: "questionmark.circle") { showHelp.toggle() }
                .popover(isPresented: $showHelp) { Text(QUERY_HELP).font(.callout.monospaced()).padding().textSelection(.enabled) }
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.trailing") { model.showInspector.toggle() }
        }
    }
}

struct VerdictBadge: View {
    let verdict: String
    var body: some View {
        Text(verdict.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(COLORS[verdict] ?? .gray)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((COLORS[verdict] ?? .gray).opacity(0.16), in: .capsule)
    }
}

struct StatusBar: View {
    var model: Model
    var body: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(VERDICTS.filter { model.counts[$0, default: 0] > 0 }, id: \.self) { v in
                        Button {
                            model.view = v == "Fake" ? .fake : v == "Suspect" ? .suspect : .all
                        } label: {
                            Label("\(model.counts[v]!) \(v)", systemImage: "circle.fill")
                                .labelStyle(TallyLabel(color: COLORS[v] ?? .gray))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }
            Spacer()
            if model.scanning {
                Text("\(model.done) / \(model.total)  \(model.eta)").monospacedDigit().foregroundStyle(.secondary)
                ProgressView(value: Double(model.done), total: Double(max(model.total, 1))).frame(width: 180)
            } else if !model.results.isEmpty {
                Text("\(model.filtered.count) of \(model.results.count) shown").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct TallyLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color).font(.system(size: 7))
            configuration.title.monospacedDigit()
        }
    }
}

// MARK: sidebar
struct Sidebar: View {
    @Bindable var model: Model

    var body: some View {
        List(selection: $model.folder) {
            Section("Show") {
                Picker("Show", selection: $model.view) {
                    ForEach(VerdictView.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            if !model.folders.isEmpty {
                Section("Folders") {
                    HStack {
                        Label("All", systemImage: "tray.2")
                        Spacer()
                        if let n = model.counts["Fake"] { Text("\(n)").foregroundStyle(COLORS["Fake"]!).monospacedDigit() }
                        Text("\(model.results.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag("")  // plain String tag: List matches tags against String, an Optional tag never matches
                    ForEach(model.folders, id: \.path) { f in
                        HStack {
                            Label(f.name, systemImage: "folder")
                            Spacer()
                            if f.fake > 0 {
                                Text("\(f.fake)").foregroundStyle(COLORS["Fake"]!).monospacedDigit()
                                    .help("\(f.fake) fake of \(f.total)")
                            }
                            Text("\(f.total)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(f.path)
                        .help(f.path)
                        .contextMenu { Button("Remove from Sidebar") { model.removeFolder(f.path) } }
                    }
                }
            }
            Section {
                ForEach(RANGES, id: \.field) { r in
                    RangeRow(label: r.label, state: $model.ranges[r.field].unwrapped)
                }
                Toggle("Lossy files only (MP3/AAC…)", isOn: $model.lossyOnly)
            } header: {
                HStack {
                    Text("Filters")
                    Spacer()
                    Menu("Presets") {
                        ForEach(PRESETS, id: \.name) { p in Button(p.name) { model.applyPreset(p) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button("Reset") { model.resetFilters() }.buttonStyle(.borderless)
                }
            }
            .disabled(model.results.isEmpty || model.scanning)
        }
        .listStyle(.sidebar)
    }
}

extension Binding where Value == RangeState? {
    var unwrapped: Binding<RangeState> { Binding<RangeState>(get: { wrappedValue! }, set: { wrappedValue = $0 }) }
}

/// Label, min field · two-thumb slider · max field. Slider spans the scanned data; fields accept any value.
struct RangeRow: View {
    let label: String
    @Binding var state: RangeState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(state.loOn || state.hiOn ? .primary : .secondary)
            HStack(spacing: 6) {
                field($state.lo)
                RangeSlider(state: $state).frame(height: 16)
                field($state.hi)
            }
        }
        .disabled(!state.enabled)
        .padding(.vertical, 2)
    }

    func field(_ v: Binding<Double>) -> some View {
        TextField("", value: v, format: .number.precision(.fractionLength(state.decimals)))
            .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 58)
            .multilineTextAlignment(.trailing)
    }
}

/// Two-handle slider; SwiftUI has none built in.
struct RangeSlider: View {
    @Binding var state: RangeState
    @State private var dragging: Bool?  // true = lo handle

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 12, span = max(state.maxB - state.minB, 1e-12)
            let x = { (v: Double) in 6 + CGFloat(min(1, max(0, (v - state.minB) / span))) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 3).padding(.horizontal, 6)
                Capsule().fill(state.enabled ? Color.accentColor : .secondary)
                    .frame(width: max(0, x(state.hi) - x(state.lo)), height: 3).offset(x: x(state.lo))
                ForEach([x(state.lo), x(state.hi)].indices, id: \.self) { i in
                    let cx = i == 0 ? x(state.lo) : x(state.hi)
                    Circle().fill(.background).stroke(Color.accentColor, lineWidth: 1).frame(width: 12, height: 12)
                        .shadow(radius: 1).offset(x: cx - 6)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let f = min(1, max(0, Double((d.location.x - 6) / w)))
                let v = (state.minB + f * span).rounded(toPlaces: state.decimals)
                if dragging == nil { dragging = abs(d.startLocation.x - x(state.lo)) < abs(d.startLocation.x - x(state.hi)) || d.startLocation.x < x(state.lo) }
                if dragging! { state.lo = min(v, state.hi) } else { state.hi = max(v, state.lo) }
            }.onEnded { _ in dragging = nil })
        }
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double { let k = pow(10, Double(p)); return (self * k).rounded() / k }
}

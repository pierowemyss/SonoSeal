import AnalyzerCore
import AppKit
import SwiftUI

/// (sortTracks key, title, width, monospaced digits, cell text)
@MainActor let COLUMNS: [(id: String, title: String, width: CGFloat, mono: Bool, text: (TrackResult) -> String)] = [
    ("name", "Name", 280, false, \.name),
    ("artist", "Artist", 140, false, { $0.artist ?? "" }),
    ("verdict", "Verdict", 76, false, { $0.verdict.uppercased() }),
    ("conf", "Conf %", 52, true, { "\($0.confidence)" }),
    ("format", "Format", 100, false, fmtOf),
    ("kbps", "kbps", 48, true, { $0.claimedKbps.map(String.init) ?? "" }),
    ("cutoff", "Cutoff kHz", 66, true, { fmtNum($0.cutoffHz.map { $0 / 1000 }) }),
    ("est", "Est. source", 80, false, \.estQuality),
    ("dr", "DR", 34, true, { fmtNum($0.dr, "%.0f") }),
    ("peak", "Peak", 44, true, { fmtNum($0.peakDb) }),
    ("rms", "RMS", 44, true, { fmtNum($0.rmsDb) }),
    ("clips", "Clips", 44, true, { $0.clipEvents.map(String.init) ?? "" }),
    ("added", "Added", 86, true, { $0.added?.formatted(date: .abbreviated, time: .omitted) ?? "" }),
]

func fmtNum(_ v: Double?, _ f: String = "%.1f") -> String { v.map { String(format: f, $0) } ?? "" }

/// Native NSTableView: a change reloads only the visible rows. SwiftUI's Table diffed every row and hosted
/// a SwiftUI view per cell, which took seconds per filter/sort/selection change at 20k tracks.
struct TrackTable: NSViewRepresentable {
    var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator, t = c.table
        for col in COLUMNS {
            let tc = NSTableColumn(identifier: .init(col.id))
            tc.title = col.title
            tc.width = col.width
            tc.minWidth = 30
            tc.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: col.id != "added")
            t.addTableColumn(tc)
        }
        t.autosaveName = "tracks"  // column widths + order survive re-sorts and relaunches
        t.autosaveTableColumns = true
        t.style = .inset
        t.usesAlternatingRowBackgroundColors = true
        t.allowsMultipleSelection = true
        t.allowsColumnReordering = true
        t.dataSource = c
        t.delegate = c
        t.target = c
        t.doubleAction = #selector(Coordinator.doubleClick)
        t.menu = c.makeMenu()
        t.onDelete = { [weak c] in c?.model.trash() }
        let s = NSScrollView()
        s.documentView = t
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        return s
    }

    func updateNSView(_ s: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        if c.generation != model.generation {
            c.generation = model.generation
            c.rows = model.filtered
            c.index = nil
            c.quietly { c.table.reloadData() }
        }
        c.syncSelection(model.selection)
        let want = COLUMNS.contains { $0.id == model.sort.key } ? [NSSortDescriptor(key: model.sort.key, ascending: model.sort.ascending)] : []
        if c.table.sortDescriptors != want { c.quietly { c.table.sortDescriptors = want } }  // Sort menu -> header arrow
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: Model
        let table = KeyTable()
        var rows: [TrackResult] = []
        var generation = -1
        var index: [String: Int]?  // path -> row, built only when a selection needs restoring
        private var updating = false

        init(_ model: Model) { self.model = model }

        /// Run a programmatic table change without echoing it back into the model.
        func quietly(_ f: () -> Void) { updating = true; f(); updating = false }

        func syncSelection(_ paths: Set<String>) {
            let want: IndexSet
            if paths.isEmpty {
                want = []
            } else {
                if index == nil { index = Dictionary(rows.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a }) }
                want = IndexSet(paths.compactMap { index![$0] })
            }
            if table.selectedRowIndexes != want { quietly { table.selectRowIndexes(want, byExtendingSelection: false) } }
        }

        func numberOfRows(in _: NSTableView) -> Int { rows.count }

        func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let id = col?.identifier, let spec = COLUMNS.first(where: { $0.id == id.rawValue }) else { return nil }
            let cell = t.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id, mono: spec.mono)
            let r = rows[row], f = cell.textField!
            f.stringValue = spec.text(r)
            if id.rawValue == "verdict" { f.textColor = NSColor(COLORS[r.verdict] ?? .gray) }
            if id.rawValue == "name" { f.toolTip = r.reason }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier, mono: Bool) -> NSTableCellView {
            let cell = NSTableCellView(), f = NSTextField(labelWithString: "")
            cell.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.font = id.rawValue == "verdict" ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
                : mono ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(f)
            cell.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_: Notification) {
            guard !updating else { return }
            let sel = Set(table.selectedRowIndexes.map { rows[$0].path })
            if sel != model.selection { model.selection = sel }
        }

        func tableView(_ t: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard !updating, let d = t.sortDescriptors.first, let k = d.key else { return }
            model.sort = (k, d.ascending)
        }

        // MARK: menu, double-click
        func makeMenu() -> NSMenu {
            func item(_ title: String, _ icon: String, _ a: Selector) -> NSMenuItem {
                let i = NSMenuItem(title: title, action: a, keyEquivalent: "")
                i.target = self
                i.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                return i
            }
            let m = NSMenu()
            m.items = [item("Reveal in Finder", "folder", #selector(reveal)), item("Copy Path", "doc.on.doc", #selector(copyPaths)),
                       .separator(), item("Apply Finder Tags", "tag", #selector(tag)), item("Move to Trash", "trash", #selector(trash))]
            m.autoenablesItems = false
            m.delegate = self
            return m
        }

        func menuNeedsUpdate(_ m: NSMenu) { for i in m.items { i.isEnabled = table.clickedRow >= 0 } }

        /// Right-clicked row's selection if it's selected, else just that row.
        private var clicked: Set<String> {
            let r = table.clickedRow
            guard r >= 0, r < rows.count else { return [] }
            return table.selectedRowIndexes.contains(r) ? model.selection : [rows[r].path]
        }

        @objc func reveal() { model.reveal(clicked) }
        @objc func copyPaths() { model.copyPaths(clicked) }
        @objc func tag() { model.tag(clicked) }
        @objc func trash() { model.trash(clicked) }
        @objc func doubleClick() { if table.clickedRow >= 0 { model.showInspector = true } }
    }
}

final class KeyTable: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if e.specialKey == .delete || e.specialKey == .deleteForward { onDelete?() } else { super.keyDown(with: e) }
    }
}

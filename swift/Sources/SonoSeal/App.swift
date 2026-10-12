import AnalyzerCore
import AppKit
import SwiftUI

@main enum Entry {
    static func main() {
        // CLI mode, like `python analyze.py FILE...`: SonoSeal FILE [FILE ...]
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        guard files.isEmpty else { return cli(files) }
        AnalyzerApp.main()
    }

    static func cli(_ files: [String]) {
        for p in files {
            do {
                let r = try analyze(URL(fileURLWithPath: p))
                print(r.verdict.padding(toLength: 7, withPad: " ", startingAt: 0), "\(r.confidence)%", r.codec ?? "?",
                      "\(r.claimedKbps ?? 0)k", String(format: "cutoff %.1f kHz (drop %.0f dB)  DR %.1f  peak %.1f  clips %d  corr %.2f ",
                                                        (r.cutoffHz ?? 0) / 1000, r.wallDb ?? 0, r.dr ?? 0, r.peakDb ?? 0,
                                                        r.clipEvents ?? 0, r.correlation ?? 0), r.reason, "[\(p)]")
            } catch {
                print("Error  ", error, "[\(p)]")
            }
        }
    }
}

struct AnalyzerApp: App {
    @State private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.regular) }  // also a proper app when run unbundled via `swift run`

    var body: some Scene {
        Window("SonoSeal", id: "main") {
            ContentView(model: model)  // no window min frame: it fights .inspectorColumnWidth into a constraint loop
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Import Rekordbox XML / M3U…") { model.importPlaylist() }.keyboardShortcut("i")
                Divider()
                Button("Export CSV…") { model.exportCSV() }.keyboardShortcut("e").disabled(model.filtered.isEmpty)
            }
            CommandMenu("Tracks") {
                Button(model.scanning ? "Stop Scan" : "Rescan") { model.scanning ? model.stop() : model.rescan() }
                    .keyboardShortcut("r")
                Divider()
                Button("Reveal in Finder") { model.reveal() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("Apply Finder Tags") { model.tag() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("Move to Trash") { model.trash() }.keyboardShortcut(.delete)
                    .disabled(model.selection.isEmpty)
            }
        }
    }
}

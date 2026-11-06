import AppKit
import SwiftUI
import TallshotCore
import TallshotExport

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Output").tag(1)
                Text("Capture").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.top, 14)
            Group {
                switch tab {
                case 0: general
                case 1: output
                default: capture
                }
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 132).fixedSize(horizontal: false, vertical: true)
    }

    func warning(_ slot: UInt32) -> some View {
        Group {
            if let w = model.hotkeyWarnings[slot] {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 132).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Capture hotkey") {
                HotkeyRecorder(hotkey: $settings.captureHotkey, allowNone: false) { old in model.hotkeyChanged(slot: 1, previous: old) }
            }
            warning(1)
            row("Capture from top") {
                HotkeyRecorder(hotkey: $settings.fromTopHotkey, allowNone: true) { old in model.hotkeyChanged(slot: 2, previous: old) }
            }
            warning(2)
            Divider()
            row("Capture") {
                Picker("", selection: $settings.captureMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            hint("Pane under the pointer captures just the panel, pane or browser tab you point at: no app sidebar, no browser toolbar. The outline that flashes first shows the pick; press Esc if it's wrong.")
            Divider()
            row("") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
    }

    var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Save to") {
                HStack {
                    Text(settings.folderURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
            row("File names") {
                Picker("", selection: $settings.descriptiveFileNames) {
                    Text("App, title and date").tag(true)
                    Text("Date only").tag(false)
                }
                .labelsHidden().frame(width: 200)
            }
            hint("Chrome also adds the site's domain. Private windows and password fields never add anything, and browsers that can't show whether a window is private use only the app and date.")
            row("Also save as") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("PNG", isOn: $settings.saveToFolder)
                    Toggle("PDF", isOn: $settings.savePDF)
                    Toggle("Word (.docx)", isOn: $settings.saveDOCX)
                    if settings.saveDOCX {
                        Toggle("Include the image in the Word file", isOn: $settings.wordIncludesImage).padding(.leading, 20)
                    }
                    Toggle("Markdown (.md)", isOn: $settings.saveMarkdown)
                }
            }
            hint("Word and Markdown get the words, with headings, lists, links and code: read from the app when it shares them, otherwise recognized from the image on this Mac. The PDF is searchable.")
            row("PDF page size") {
                Picker("", selection: $settings.pdfPageSize) {
                    ForEach(PageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            Divider()
            row("Clipboard") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                    Picker("Copy as", selection: $settings.copyAs) {
                        ForEach(CopyAs.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 240).disabled(!settings.copyToClipboard)
                }
            }
            Divider()
            row("After capture") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show a preview pop-up", isOn: $settings.showToast)
                    Text("A small preview in the corner for 3 seconds. Click it to open the file.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Play a shutter sound", isOn: $settings.shutterSound)
                }
            }
        }
    }

    var capture: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Scroll speed") {
                Picker("", selection: $settings.scrollSpeed) {
                    ForEach(ScrollSpeed.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            hint("Careful takes smaller steps and waits longer, for slow or animated pages.")
            row("Height limit") {
                Picker("", selection: $settings.maxHeight) {
                    ForEach([10_000, 20_000, 30_000, 50_000], id: \.self) { Text(Delivery.pixels($0)).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            if settings.maxHeight >= 50_000 {
                hint("Very tall images may be shrunk by chat apps when you paste them. The PDF keeps them readable, page by page.")
            }
            row("Time limit") {
                Picker("", selection: $settings.maxSeconds) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            hint("Very long pages that keep loading more stop at these limits.")
            Divider()
            row("Diagnostics") {
                Toggle("Keep a diagnostic report when a capture stops early", isOn: $settings.keepDiagnostics)
            }
            if settings.keepDiagnostics {
                row("Save reports to") {
                    HStack {
                        Text(settings.diagnosticsFolder?.lastPathComponent ?? "Next to the capture").lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseDiagnosticsFolder)
                        if settings.diagnosticsFolder != nil {
                            Button("Next to the Capture") { settings.diagnosticsFolder = nil }
                        }
                    }
                }
            }
            hint("Saves a folder with the capture's frames and a log of each scroll step, so you can share one folder instead of a screen recording. The frames are pictures of what you captured. Stays on this Mac; nothing is sent anywhere. Off by default.")
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: 120, alignment: .trailing).foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.folderURL
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url }
    }

    func chooseDiagnosticsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.diagnosticsFolder ?? settings.folderURL
        panel.prompt = "Save Reports Here"
        if panel.runModal() == .OK, let url = panel.url { settings.diagnosticsFolder = url }
    }
}

/// Click, then press a key combo. Esc cancels; Delete clears (when allowed).
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    var allowNone: Bool
    /// Called after a change, with the hotkey it replaced.
    var onChange: (Hotkey?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : (hotkey?.display ?? "None"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            if allowNone && hotkey != nil && !recording {
                Button("Clear") { let old = hotkey; hotkey = nil; onChange(old) }.buttonStyle(.link)
            }
        }
        .onDisappear(perform: stop)
    }

    func toggle() { recording ? stop() : start() }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                         // Esc
            if e.keyCode == 51 && allowNone { let old = hotkey; hotkey = nil; onChange(old); stop(); return nil }   // Delete
            if let h = Hotkey(event: e) { let old = hotkey; hotkey = h; onChange(old); stop() }
            return nil
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

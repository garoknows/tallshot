import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Capture").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, 14)
            Group {
                if tab == 0 { general } else { capture }
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Capture hotkey") {
                HotkeyRecorder(hotkey: $settings.captureHotkey, allowNone: false) { model.registerHotkeys() }
            }
            row("Capture from top") {
                HotkeyRecorder(hotkey: $settings.fromTopHotkey, allowNone: true) { model.registerHotkeys() }
            }
            if let p = model.hotkeyProblem { Text(p).font(.caption).foregroundStyle(.red) }
            Divider()
            row("Save to") {
                HStack {
                    Text(settings.folderURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
                .disabled(!settings.saveToFolder)
            }
            row("After capture") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                    Toggle("Save a PNG", isOn: $settings.saveToFolder)
                    Toggle("Show a toast", isOn: $settings.showToast)
                    Toggle("Play a shutter sound", isOn: $settings.shutterSound)
                }
            }
            Divider()
            row("") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
    }

    var capture: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Scroll speed") {
                Picker("", selection: $settings.scrollSpeed) {
                    ForEach(ScrollSpeed.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            Text("Careful takes smaller steps and waits longer, for slow or animated pages.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 132)
            row("Height limit") {
                Picker("", selection: $settings.maxHeight) {
                    ForEach([10_000, 20_000, 30_000, 50_000], id: \.self) { Text(Delivery.pixels($0)).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            row("Time limit") {
                Picker("", selection: $settings.maxSeconds) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            Text("Very long pages that keep loading more stop at these limits.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 132)
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
}

/// Click, then press a key combo. Esc cancels; Delete clears (when allowed).
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    var allowNone: Bool
    var onChange: () -> Void
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
                Button("Clear") { hotkey = nil; onChange() }.buttonStyle(.link)
            }
        }
        .onDisappear(perform: stop)
    }

    func toggle() { recording ? stop() : start() }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                         // Esc
            if e.keyCode == 51 && allowNone { hotkey = nil; onChange(); stop(); return nil }   // Delete
            if let h = Hotkey(event: e) { hotkey = h; onChange(); stop() }
            return nil
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

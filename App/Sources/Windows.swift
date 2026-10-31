import AppKit
import SwiftUI
import Carbon.HIToolbox
extension Hotkey {
    var keyEquivalent: KeyEquivalent? {
        let name = Hotkey.keyName(keyCode)
        guard name.count == 1, let c = name.lowercased().first else { return nil }
        return KeyEquivalent(c)
    }
    var eventModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        return m
    }
}

/// Opens Tallshot's few windows. They're plain AppKit windows hosting SwiftUI views, which
/// open reliably from a menu bar app with no Dock icon.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, _ view: V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func showSettings() { show("settings", title: "Tallshot Settings", SettingsView(settings: Settings.shared, model: AppModel.shared)) }
    func showSetup() { show("setup", title: "Set Up Tallshot", SetupView()) }
    func close(_ id: String) { windows[id]?.close() }
}

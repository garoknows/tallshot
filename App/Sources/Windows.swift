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
    private var closeObservers: [String: NSObjectProtocol] = [:]

    /// A closed window is let go, with its view, and made again the next time it's opened.
    private func forget(_ id: String) {
        if let o = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
        windows.removeValue(forKey: id)?.contentView = nil
    }

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
        // Closing tears the view down, so the setup window's once-a-second permission check
        // stops instead of running on behind a hidden window.
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(id) }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func showSettings() { show("settings", title: "Tallshot Settings", SettingsView(settings: Settings.shared, model: AppModel.shared)) }
    func showSetup() { show("setup", title: "Set Up Tallshot", SetupView()) }
    func close(_ id: String) { windows[id]?.close() }
}

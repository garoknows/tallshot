import AppKit
import SwiftUI
import Carbon.HIToolbox
import TallshotCore
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

    /// Opens the window, or brings it back if it's open. `replace` swaps an open window's view for
    /// this one (a new check result).
    func show<V: View>(_ id: String, title: String, _ view: V, replace: Bool = false) {
        if let w = windows[id] {
            if replace {
                w.title = title
                w.contentView = NSHostingView(rootView: view)
                // Grow or shrink downward: the title bar stays where it was.
                let topLeft = NSPoint(x: w.frame.minX, y: w.frame.maxY)
                if let size = w.contentView?.fittingSize, size.width > 0, size.height > 0 { w.setContentSize(size) }
                w.setFrameTopLeftPoint(topLeft)
            }
            Self.present(w)
            return
        }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        if let size = w.contentView?.fittingSize, size.width > 0, size.height > 0 { w.setContentSize(size) }
        w.isReleasedWhenClosed = false
        windows[id] = w
        // Closing tears the view down, so the setup window's once-a-second permission check
        // stops instead of running on behind a hidden window.
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(id) }
        }
        Self.present(w, isNew: true)
    }

    /// Every Tallshot window opens in front and on the display with the pointer. A window already
    /// on that display stays where it was; one on another display moves over (`move: false`
    /// keeps it put, for the self-test page just after its capture). macOS may decline to make
    /// Tallshot the active app (it was started from Terminal, or another app is busy), so the
    /// window is also ordered in front regardless, which macOS always allows.
    static func present(_ w: NSWindow, isNew: Bool = false, move: Bool = true) {
        if move {
            let screens = NSScreen.screens.map { WindowOpening.Screen(frame: $0.frame, visible: $0.visibleFrame) }
            let f = WindowOpening.frame(size: w.frame.size, pointer: NSEvent.mouseLocation, screens: screens,
                                          current: isNew ? nil : w.frame)
            if f != w.frame { w.setFrame(f, display: false) }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func showSettings() { show("settings", title: "Tallshot Settings", SettingsView(settings: Settings.shared, model: AppModel.shared)) }
    func showSetup() { show("setup", title: "Set Up Tallshot", SetupView()) }
    func close(_ id: String) { windows[id]?.close() }
}

/// Remembers the app that was in front before Tallshot's menu opened, for Check This App.
@MainActor
final class FrontApp {
    static let shared = FrontApp()
    private var memory = FrontAppMemory(own: ProcessInfo.processInfo.processIdentifier,
                                        front: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    private var observers: [NSObjectProtocol] = []

    var pid: pid_t? { memory.pid }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.memory.activated(pid) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.memory.terminated(pid) } }
        })
    }
}

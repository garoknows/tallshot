import AppKit
import SwiftUI

/// The real entry point. The permission check has to run before any of the app starts up.
@main
enum TallshotEntry {
    static func main() {
        if CommandLine.arguments.contains(Permissions.checkScreenRecordingFlag) {
            exit(CGPreflightScreenCaptureAccess() ? Permissions.screenRecordingOnExit : Permissions.screenRecordingOffExit)
        }
        TallshotApp.main()
    }
}

struct TallshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared
    @ObservedObject var settings = Settings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, settings: settings)
        } label: {
            Image(nsImage: MenuBarIcon.image(filled: model.isCapturing))
                .accessibilityLabel("Tallshot")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// `tallshot://capture` and friends, from Raycast, Shortcuts, scripts or a browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(AppModel.shared.open) }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        Button("Capture Now") { captureSoon(fromTop: false) }
            .keyboardShortcut(settings.captureHotkey)
        Button("Capture from Top") { captureSoon(fromTop: true) }
            .keyboardShortcut(settings.fromTopHotkey)
        Divider()
        if !Permissions.allGranted {
            Button("Finish Setup…") { WindowRouter.shared.showSetup() }
        }
        Button("Settings…") { WindowRouter.shared.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Run Self-Test") { SelfTest.shared.run() }
        Divider()
        Button("Quit Tallshot") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// From the menu, the pointer is on the menu bar: capture what's under it once the menu closes.
    /// The pointer usually sits over the window the user wants once they move away from the menu,
    /// so Capture Now from the menu uses the front window's scrolling area.
    func captureSoon(fromTop: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.capture(fromTop: fromTop) }
    }
}

extension View {
    /// Shows a Carbon hotkey next to a menu item (display only; Carbon handles the key itself).
    @ViewBuilder func keyboardShortcut(_ hotkey: Hotkey?) -> some View {
        if let hotkey, let key = hotkey.keyEquivalent {
            self.keyboardShortcut(key, modifiers: hotkey.eventModifiers)
        } else {
            self
        }
    }
}


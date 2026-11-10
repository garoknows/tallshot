import AppKit
import SwiftUI
import TallshotCore

/// The real entry point. The permission check has to run before any of the app starts up.
@main
enum TallshotEntry {
    static func main() {
        if CommandLine.arguments.contains(Permissions.checkScreenRecordingFlag) {
            exit(CGPreflightScreenCaptureAccess() ? Permissions.screenRecordingOnExit : Permissions.screenRecordingOffExit)
        }
        // For scripts/test-version.sh: exits 0 if the menu's version line is exactly the given text.
        if let i = CommandLine.arguments.firstIndex(of: "--menu-version-is"), i + 1 < CommandLine.arguments.count {
            exit(MenuContent.versionLine == CommandLine.arguments[i + 1] ? 0 : 1)
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

    /// "Tallshot 1.1.1", read from this app's own Info.plist, so it can't go out of date.
    static var versionLine: String { AppVersion.title(info: Bundle.main.infoDictionary) }

    var body: some View {
        Button(Self.versionLine) {}
            .disabled(true)
        Divider()
        Button("Capture Now") { captureSoon(fromTop: false) }
            .keyboardShortcut(settings.captureHotkey)
        Button("Capture from Top") { captureSoon(fromTop: true) }
            .keyboardShortcut(settings.fromTopHotkey)
        Button("Capture as Image") { captureSoon(fromTop: false, asImage: true) }
            .keyboardShortcut(settings.imageHotkey)
        Divider()
        if !Permissions.allGranted {
            Button("Finish Setup…") { WindowRouter.shared.showSetup() }
        }
        Button("Settings…") { WindowRouter.shared.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Run Self-Test") { SelfTest.shared.run() }
        // Opens the page in the browser. Tallshot itself makes no network connection.
        Button("Release Notes…") { if let url = URL(string: AppVersion.releaseNotesAddress) { NSWorkspace.shared.open(url) } }
        Divider()
        Button("Quit Tallshot") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// From the menu, capture the front window once the menu has closed. The pointer is on the
    /// menu's own item, over whatever window happens to be behind it, so it isn't used.
    func captureSoon(fromTop: Bool, asImage: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.capture(fromTop: fromTop, fromMenu: true, asImage: asImage) }
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


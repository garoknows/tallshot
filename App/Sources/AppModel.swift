import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import TallshotCore
import TallshotExport

/// The two permissions Tallshot needs.
enum Permissions {
    /// Screen Recording: lets ScreenCaptureKit take pictures of other apps' windows.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// Accessibility: lets Tallshot find the scrolling area under the pointer and send scroll events.
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var allGranted: Bool { screenRecording && accessibility }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Run with this flag, Tallshot only reports what macOS says about Screen Recording, then exits.
    static let checkScreenRecordingFlag = "--check-screen-recording"
    static let screenRecordingOnExit: Int32 = 40, screenRecordingOffExit: Int32 = 41

    /// macOS gives a running app the same Screen Recording answer until it restarts. A new process
    /// gets the current one, so this asks a second copy of Tallshot that exits at once.
    /// Answers nil if that couldn't be found out.
    nonisolated static func askFreshProcessAboutScreenRecording(_ done: @escaping @Sendable (Bool?) -> Void) {
        guard let exe = Bundle.main.executableURL else { done(nil); return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [checkScreenRecordingFlag]
        p.terminationHandler = { q in
            switch q.terminationStatus {
            case screenRecordingOnExit: done(true)
            case screenRecordingOffExit: done(false)
            default: done(nil)
            }
        }
        do { try p.run() } catch { done(nil) }
    }

    /// Quits, and opens this same copy of Tallshot again once it has fully quit, so the old copy
    /// and the new one never compete for the hotkey.
    static func quitAndReopen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"while kill -0 "$0" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$1""#,
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

/// The app's state and the capture flow, from hotkey to toast.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings = Settings.shared
    @Published private(set) var isCapturing = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hotkeyProblem: String?

    private init() {}

    func start() {
        registerHotkeys()
        if !Permissions.allGranted || !settings.setupShown { WindowRouter.shared.showSetup() }
    }

    /// Warnings shown right under each hotkey field (slot 1: capture, slot 2: from top).
    @Published var hotkeyWarnings: [UInt32: String] = [:]

    @discardableResult
    func registerHotkeys() -> [UInt32: Bool] {
        var ok: [UInt32: Bool] = [:]
        ok[1] = HotKeys.shared.set(1, settings.captureHotkey, action: { [weak self] in self?.capture(fromTop: false) })
        ok[2] = HotKeys.shared.set(2, settings.fromTopHotkey, action: { [weak self] in self?.capture(fromTop: true) })
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var warnings: [UInt32: String] = [:]
        for (slot, key) in [(UInt32(1), settings.captureHotkey), (2, settings.fromTopHotkey)] {
            guard let key else { continue }
            if let w = HotkeyConflicts.warning(keyCode: key.keyCode, modifiers: key.modifiers, registered: ok[slot] ?? false,
                                               systemTaken: SystemShortcuts.uses(key), running: running) {
                warnings[slot] = w
            }
        }
        hotkeyWarnings = warnings
        hotkeyProblem = warnings.isEmpty ? nil : warnings.values.first
        return ok
    }

    /// A hotkey was recorded. One macOS refuses is never kept: the old one comes back, and the
    /// field says why.
    func hotkeyChanged(slot: UInt32, previous: Hotkey?) {
        let ok = registerHotkeys()
        guard ok[slot] == false else { return }
        let refused = (slot == 1 ? settings.captureHotkey : settings.fromTopHotkey)?.display ?? ""
        if slot == 1 { settings.captureHotkey = previous } else { settings.fromTopHotkey = previous }
        registerHotkeys()
        hotkeyWarnings[slot] = "macOS refused \(refused) (another app has it), so it wasn't kept. Pick a different one."
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Toast.show(message: "Couldn't change launch at login.", detail: error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Handles `tallshot://capture` and `tallshot://capture?from=top`.
    func open(_ url: URL) {
        guard url.scheme == "tallshot" else { return }
        let fromTop = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "from" && $0.value == "top" } ?? false
        switch url.host {
        case "capture": capture(fromTop: fromTop)
        case "selftest", "self-test": SelfTest.shared.run()
        case "settings": WindowRouter.shared.showSettings()
        default: break
        }
    }

    /// One capture: find the area under the pointer, scroll and stitch, then deliver.
    func capture(fromTop: Bool) {
        guard !isCapturing else { return }
        guard Permissions.allGranted else { WindowRouter.shared.showSetup(); return }
        let pointer = TargetFinder.pointerLocation()
        // Pointing at the self-test page and pressing the hotkey runs the self-test the real way.
        if SelfTest.shared.contains(pointer) { SelfTest.shared.runFromHotkey(); return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            guard let (target, axSwitch) = await TargetFinder.find(at: pointer, mode: settings.captureMode) else {
                Toast.show(message: "Nothing to capture here.", detail: "Point at a window and try again.")
                return
            }
            defer { axSwitch?.restore() }
            let date = Date()
            do {
                let run = try await Self.run(target: target, options: settings.captureOptions(fromTop: fromTop), collectText: settings.needsText)
                await deliver(run.result, capturer: run.capturer, target: target, text: run.text, date: date)
            } catch is CancellationError {
                Toast.show(message: "Cancelled.", detail: "Nothing was saved or copied.", near: target.region)
            } catch {
                Toast.show(message: "Capture failed.", detail: error.localizedDescription, near: target.region)
            }
        }
    }

    /// The capture itself, shared with the self-test. Frames stay in memory only (and, only
    /// when the diagnostics setting is on, in the report of a capture that stopped early).
    struct Run {
        var result: CaptureResult
        var capturer: WindowCapturer
        /// The pane's text from the accessibility tree, when it was collected.
        var text: ExportDocument?
    }

    static func run(target: CaptureTarget, options: CaptureOptions, hotkeyKeyCode: UInt32? = nil, collectText: Bool = false) async throws -> Run {
        // The flash shows exactly the pane that will be captured, before anything scrolls.
        // Esc (or any key, click or mouse move) while it shows cancels with nothing saved.
        RegionFlash.show(target.region, seconds: 0.7)
        // The hotkey's keys are often still held: wait (up to 2 s) until they're let go, so they
        // can't change how the app reads the scroll, and so a held key can't cancel the capture.
        let key = hotkeyKeyCode ?? Settings.shared.captureHotkey?.keyCode
        _ = await ModifierKeys.waitUntilReleased(
            flags: { CGEventSource.flagsState(.combinedSessionState) },
            otherKeyHeld: { key.map { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) } ?? false },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try? await Task.sleep(for: .milliseconds($0)) })
        var options = options
        options.cropToMovingColumns = target.cropToMovement
        if target.isBrowserLike { options.cautiousStartFraction = 0.3 }
        let capturer = try await WindowCapturer(target: target)
        let driver = LiveDriver(target: target, capturer: capturer)
        if collectText, let root = target.textRoot { driver.collector = TextCollector(root: root, region: target.region) }
        driver.begin()
        defer { driver.end() }
        try await Task.sleep(for: .milliseconds(560))   // the flash, then let it fade before the first picture
        if driver.isCancelled { throw CancellationError() }
        let result = try await CaptureSession(driver: driver, options: options).run()
        return Run(result: result, capturer: capturer, text: driver.collector?.document)
    }

    /// The pop-up text for a finished capture: an early stop says so plainly with the reason,
    /// and a capture of a Tallshot test page gets its barcode verdict.
    static func popUpText(_ result: CaptureResult, saved: String) -> (message: String, detail: String?) {
        var lines: [String] = []
        if result.reason.isEarly { lines.append(result.reason.note) }
        if result.steps > 0, result.image.height - result.footer > result.header,
           let v = BarcodeCheck.verdict(for: result.image, rows: result.header..<(result.image.height - result.footer)) {
            lines.append(v.message)
        }
        let message = result.reason.headline.map { "\($0). \(saved)" } ?? saved
        return (message, lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    private func deliver(_ result: CaptureResult, capturer: WindowCapturer, target: CaptureTarget, text: ExportDocument?, date: Date) async {
        let slow = settings.savePDF || settings.saveDOCX || settings.saveMarkdown || settings.needsText
        if slow { Toast.show(message: "Making the files…", detail: settings.savePDF ? "Reading the text for the PDF on this Mac." : nil, near: target.region, seconds: 30) }
        let outcome = await Delivery.deliver(result.image, colorSpace: capturer.colorSpace, settings: settings, accessibilityText: text, date: date)
        if settings.shutterSound { NSSound(named: "Pop")?.play() }
        var (message, detail) = Self.popUpText(result, saved: Delivery.message(outcome))
        var extra: [String] = []
        if let line = Delivery.exportsLine(outcome) { extra.append(line) }
        if let src = outcome.textSource, settings.needsText { extra.append(src.note) }
        extra += outcome.notes
        if !extra.isEmpty { detail = ([detail].compactMap { $0 } + extra).joined(separator: "\n") }
        if DiagnosticsWriter.shouldWrite(settingOn: settings.keepDiagnostics, result: result) {
            let folder = settings.diagnosticsFolder ?? outcome.file?.deletingLastPathComponent() ?? settings.folderURL
            let base = outcome.file.map { $0.deletingPathExtension().lastPathComponent } ?? Delivery.baseName(for: date)
            let saved = DiagnosticsWriter.write(result, target: target, colorSpace: capturer.colorSpace, folder: folder, baseName: base)
            let note = saved != nil ? "Diagnostic report saved in \(folder.lastPathComponent)." : "Couldn't save the diagnostic report in \(folder.lastPathComponent)."
            detail = [detail, note].compactMap { $0 }.joined(separator: "\n")
        }
        if let e = outcome.error { detail = [e, detail].compactMap { $0 }.joined(separator: "\n") }
        let hasVerdict = detail?.contains("Barcode check") ?? false
        guard settings.showToast || slow || outcome.error != nil || result.reason.isEarly || hasVerdict else { Toast.hide(); return }
        Toast.show(message: message, detail: detail, thumbnail: outcome.thumbnail,
                   heightBadge: Delivery.pixels(result.image.height), file: outcome.file, near: target.region,
                   seconds: result.reason.isEarly || hasVerdict ? 8 : 3)
    }
}

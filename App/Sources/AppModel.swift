import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import TallshotCore

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

    func registerHotkeys() {
        var problems: [String] = []
        if !HotKeys.shared.set(1, settings.captureHotkey, action: { [weak self] in self?.capture(fromTop: false) }) {
            problems.append(settings.captureHotkey?.display ?? "")
        }
        if !HotKeys.shared.set(2, settings.fromTopHotkey, action: { [weak self] in self?.capture(fromTop: true) }) {
            problems.append(settings.fromTopHotkey?.display ?? "")
        }
        hotkeyProblem = problems.isEmpty ? nil : "Another app already uses \(problems.joined(separator: " and "))."
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
            guard let (target, axSwitch) = await TargetFinder.find(at: pointer) else {
                Toast.show(message: "Nothing to capture here.", detail: "Point at a window and try again.")
                return
            }
            defer { axSwitch?.restore() }
            let date = Date()
            do {
                let (result, capturer) = try await Self.run(target: target, options: settings.captureOptions(fromTop: fromTop))
                deliver(result, capturer: capturer, target: target, date: date)
            } catch {
                Toast.show(message: "Capture failed.", detail: error.localizedDescription, near: target.region)
            }
        }
    }

    /// The capture itself, shared with the self-test. Frames stay in memory only (and, only
    /// when the diagnostics setting is on, in the report of a capture that stopped early).
    static func run(target: CaptureTarget, options: CaptureOptions, hotkeyKeyCode: UInt32? = nil) async throws -> (CaptureResult, WindowCapturer) {
        RegionFlash.show(target.region)
        // The hotkey's keys are often still held: wait (up to 2 s) until they're let go, so they
        // can't change how the app reads the scroll, and so a held key can't cancel the capture.
        let key = hotkeyKeyCode ?? Settings.shared.captureHotkey?.keyCode
        _ = await ModifierKeys.waitUntilReleased(
            flags: { CGEventSource.flagsState(.combinedSessionState) },
            otherKeyHeld: { key.map { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) } ?? false },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try? await Task.sleep(for: .milliseconds($0)) })
        var options = options
        options.cropToMovingColumns = target.kind != .scrollArea
        if target.isBrowserLike { options.cautiousStartFraction = 0.3 }
        let capturer = try await WindowCapturer(target: target)
        let driver = LiveDriver(target: target, capturer: capturer)
        driver.begin()
        defer { driver.end() }
        try await Task.sleep(for: .milliseconds(320))   // let the flash fade before the first picture
        let result = try await CaptureSession(driver: driver, options: options).run()
        return (result, capturer)
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

    private func deliver(_ result: CaptureResult, capturer: WindowCapturer, target: CaptureTarget, date: Date) {
        let outcome = Delivery.deliver(result.image, colorSpace: capturer.colorSpace, scale: capturer.scale, settings: settings, date: date)
        if settings.shutterSound { NSSound(named: "Pop")?.play() }
        var (message, detail) = Self.popUpText(result, saved: Delivery.message(outcome))
        if DiagnosticsWriter.shouldWrite(settingOn: settings.keepDiagnostics, result: result) {
            let folder = outcome.file?.deletingLastPathComponent() ?? settings.folderURL
            let base = outcome.file.map { $0.deletingPathExtension().lastPathComponent } ?? Delivery.baseName(for: date)
            let saved = DiagnosticsWriter.write(result, target: target, colorSpace: capturer.colorSpace, folder: folder, baseName: base)
            let note = saved.map { "Diagnostic report saved: \($0.lastPathComponent)" } ?? "Couldn't save the diagnostic report."
            detail = [detail, note].compactMap { $0 }.joined(separator: "\n")
        }
        if let e = outcome.error { detail = [e, detail].compactMap { $0 }.joined(separator: "\n") }
        let hasVerdict = detail?.contains("Barcode check") ?? false
        guard settings.showToast || outcome.error != nil || result.reason.isEarly || hasVerdict else { return }
        Toast.show(message: message, detail: detail, thumbnail: outcome.thumbnail,
                   heightBadge: Delivery.pixels(result.image.height), file: outcome.file, near: target.region,
                   seconds: result.reason.isEarly || hasVerdict ? 8 : 3)
    }
}

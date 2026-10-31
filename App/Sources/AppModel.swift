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
        guard let target = TargetFinder.find(at: pointer) else {
            Toast.show(message: "Nothing to capture here.", detail: "Point at a window and try again.")
            return
        }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let (result, capturer) = try await Self.run(target: target, options: settings.captureOptions(fromTop: fromTop))
                deliver(result, capturer: capturer, region: target.region)
            } catch {
                Toast.show(message: "Capture failed.", detail: error.localizedDescription, near: target.region)
            }
        }
    }

    /// The capture itself, shared with the self-test. Frames stay in memory only.
    static func run(target: CaptureTarget, options: CaptureOptions) async throws -> (CaptureResult, WindowCapturer) {
        RegionFlash.show(target.region)
        let capturer = try await WindowCapturer(target: target)
        let driver = LiveDriver(target: target, capturer: capturer)
        driver.begin()
        defer { driver.end() }
        try await Task.sleep(for: .milliseconds(320))   // let the flash fade before the first picture
        let result = try await CaptureSession(driver: driver, options: options).run()
        return (result, capturer)
    }

    private func deliver(_ result: CaptureResult, capturer: WindowCapturer, region: CGRect) {
        let outcome = Delivery.deliver(result.image, colorSpace: capturer.colorSpace, scale: capturer.scale, settings: settings)
        if settings.shutterSound { NSSound(named: "Pop")?.play() }
        guard settings.showToast || outcome.error != nil || result.reason.isEarly else { return }
        var detail = outcome.error
        if detail == nil, result.reason.isEarly { detail = Self.earlyNote(result.reason) }
        Toast.show(message: Delivery.message(outcome), detail: detail, thumbnail: outcome.thumbnail,
                   heightBadge: Delivery.pixels(result.image.height), file: outcome.file, near: region)
    }

    static func earlyNote(_ r: StopReason) -> String {
        switch r {
        case .bottom: ""
        case .heightCap: "Stopped at the height limit."
        case .timeCap: "Stopped at the time limit."
        case .cancelled: "Stopped early. Kept what was captured."
        case .lostTrack: "Stopped early: the page changed while scrolling."
        }
    }
}

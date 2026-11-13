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
    @MainActor static func quitAndReopen() {
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
        // A time limit for every accessibility question Tallshot asks another app, so one that has
        // stopped responding can't hold Tallshot up for long (macOS's default is 6 seconds).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        FrontApp.shared.start()
        registerHotkeys()
        if !Permissions.allGranted || !settings.setupShown { WindowRouter.shared.showSetup() }
    }

    /// Warnings shown right under each hotkey field (slot 1: capture, 2: from top, 3: as image).
    @Published var hotkeyWarnings: [UInt32: String] = [:]

    @discardableResult
    func registerHotkeys() -> [UInt32: Bool] {
        var ok: [UInt32: Bool] = [:]
        ok[1] = HotKeys.shared.set(1, settings.captureHotkey, action: { [weak self] in self?.hotkeyPressed(1) })
        ok[2] = HotKeys.shared.set(2, settings.fromTopHotkey, action: { [weak self] in self?.hotkeyPressed(2) })
        ok[3] = HotKeys.shared.set(3, settings.imageHotkey, action: { [weak self] in self?.hotkeyPressed(3) })
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var warnings: [UInt32: String] = [:]
        for (slot, key) in [(UInt32(1), settings.captureHotkey), (2, settings.fromTopHotkey), (3, settings.imageHotkey)] {
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
        // The same keys as another Tallshot hotkey: macOS would refuse it, but not because of another app.
        let keys = [UInt32(1), 2, 3].reduce(into: [UInt32: HotkeyConflicts.Keys]()) { d, n in
            if let h = settings.hotkey(slot: n) { d[n] = HotkeyConflicts.Keys(keyCode: h.keyCode, modifiers: h.modifiers) }
        }
        if let other = HotkeyConflicts.sameKeys(as: slot, in: keys), let taken = settings.hotkey(slot: slot)?.display {
            settings.setHotkey(previous, slot: slot)
            registerHotkeys()
            hotkeyWarnings[slot] = "\(taken) is already the \(Self.hotkeyName(other)) hotkey. Pick a different one."
            return
        }
        let ok = registerHotkeys()
        guard ok[slot] == false else { return }
        let refused = settings.hotkey(slot: slot)?.display ?? ""
        settings.setHotkey(previous, slot: slot)
        registerHotkeys()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        hotkeyWarnings[slot] = HotkeyConflicts.refusedMessage(display: refused, running: running)
    }

    /// Settings → Test Hotkey.
    @Published private(set) var hotkeyTest = HotkeyTest()

    func startHotkeyTest() {
        hotkeyTest.start(now: ProcessInfo.processInfo.systemUptime)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HotkeyTest.timeout + 0.2))
            self?.hotkeyTest.tick(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// A registered hotkey fired: the test takes it if it's waiting, else it captures.
    private func hotkeyPressed(_ slot: UInt32) {
        if hotkeyTest.pressed(slot: slot, now: ProcessInfo.processInfo.systemUptime) { return }
        switch slot {
        case 1: capture(fromTop: false)
        case 2: capture(fromTop: true)
        default: capture(fromTop: false, asImage: true)
        }
    }

    /// Another hotkey row that already has these keys, if any.
    func slotUsing(_ h: Hotkey, except slot: UInt32) -> UInt32? {
        let all = [UInt32(1), 2, 3].reduce(into: [UInt32: HotkeyConflicts.Keys]()) { d, n in
            if let k = settings.hotkey(slot: n) { d[n] = HotkeyConflicts.Keys(keyCode: k.keyCode, modifiers: k.modifiers) }
        }
        return HotkeyConflicts.slot(using: HotkeyConflicts.Keys(keyCode: h.keyCode, modifiers: h.modifiers), except: slot, in: all)
    }

    static func hotkeyName(_ slot: UInt32) -> String {
        switch slot { case 1: "Capture"; case 2: "Capture from Top"; default: "Capture as Image" }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Toast.show(message: "Couldn't change launch at login.", detail: error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Handles `tallshot://capture`, `tallshot://capture?from=top` and `tallshot://capture?as=image`.
    func open(_ url: URL) {
        guard url.scheme == "tallshot" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fromTop = items.contains { $0.name == "from" && $0.value == "top" }
        let asImage = items.contains { $0.name == "as" && $0.value == "image" }
        switch url.host {
        case "capture": capture(fromTop: fromTop, asImage: asImage)
        case "selftest", "self-test": SelfTest.shared.run()
        case "check", "probe": checkFrontApp()
        case "settings": WindowRouter.shared.showSettings()
        default: break
        }
    }

    /// Troubleshooting → Check This App…: the app that was in front before the menu opened.
    func checkFrontApp() {
        guard !isCapturing else { return }
        guard Permissions.allGranted else { WindowRouter.shared.showSetup(); return }
        isCapturing = true
        Task { await AppCheck.run(pid: FrontApp.shared.pid); isCapturing = false }
    }

    /// One capture: find the area under the pointer. If the app shares the pane's whole text (and
    /// the setting allows), copy and save that text with no scrolling. Otherwise scroll and stitch.
    /// `asImage` (Capture as Image) always scrolls. From the menu the pointer is on the menu's
    /// own item, so it says nothing: the front window is used.
    func capture(fromTop: Bool, fromMenu: Bool = false, asImage: Bool = false) {
        guard !isCapturing else { return }
        guard Permissions.allGranted else { WindowRouter.shared.showSetup(); return }
        let pointer = fromMenu ? nil : TargetFinder.pointerLocation()
        // A pop-up from the last capture could sit over the pane and catch the scrolling.
        Toast.hideNow()
        // Pointing at the self-test page and pressing the hotkey runs the self-test the real way.
        if let pointer, SelfTest.shared.contains(pointer) { SelfTest.shared.runFromHotkey(); return }
        isCapturing = true
        Task {
            await captureOnce(pointer: pointer, fromTop: fromTop, asImage: asImage)
            isCapturing = false
            // However it ended (saved, Esc, an error, an early stop, a text capture, nothing
            // found), the pointer ends up as the app's normal pointer. See `PointerReset`.
            await LivePointer.resetAfterCapture()
        }
    }

    private func captureOnce(pointer: CGPoint?, fromTop: Bool, asImage: Bool) async {
        guard let (target, axSwitch) = await TargetFinder.find(at: pointer, mode: settings.captureMode) else {
            Toast.show(message: "Nothing to capture here.", detail: "Point at a window and try again.")
            return
        }
        defer { axSwitch?.restore() }
        // Named before anything scrolls, while the window is as the user left it.
        let baseName = settings.descriptiveFileNames
            ? CaptureName.descriptive(TargetFinder.nameFacts(for: target), date: Date())
            : CaptureName.plain(date: Date())
        var mode = asImage ? "Scrolling screenshot (Capture as Image)." : "Scrolling screenshot."
        if !asImage && settings.textCapture == .copyText && ChatApps.usesText(bundleID: target.bundleID, checked: settings.checkedApps) {
            // A chat app that keeps the whole conversation: read it all, with who said what.
            let chat = await ChatTextReader.read(target)
            if let doc = chat.document, let reading = chat.reading {
                RegionFlash.show(target.region, seconds: 0.5)
                var line = "Text capture: the whole conversation, read from \(target.appName) with no scrolling."
                if reading.rule == .none { line += " It doesn't show who said what, so there are no speaker labels." }
                await deliverText(doc, target: target, baseName: baseName, modeLine: line)
                return
            }
            if let why = chat.why { mode = "Scrolling screenshot: \(why)" }
        } else if !asImage && settings.textCapture == .copyText {
            let shared = SharedTextReader.read(target)
            if let doc = shared.document {
                RegionFlash.show(target.region, seconds: 0.5)
                await deliverText(doc, target: target, baseName: baseName)
                return
            }
            // Say why, except "no text area" in apps that aren't expected to have one.
            let expected = target.bundleID.map(PlainTextDocument.monospacedApps.contains) ?? false
            if shared.verdict != .notText || expected, let why = Self.whyNotText(shared.verdict) { mode = "Scrolling screenshot: \(why)" }
        }
        do {
            // Wait for the keys of the hotkey that was actually pressed.
            let key = (asImage ? settings.imageHotkey : fromTop ? settings.fromTopHotkey : settings.captureHotkey)?.keyCode
            let run = try await Self.run(target: target, options: settings.captureOptions(fromTop: fromTop),
                                         hotkeyKeyCode: key, collectText: settings.needsText)
            await deliver(run.result, capturer: run.capturer, target: target, text: run.text, baseName: baseName, mode: mode)
        } catch is CancellationError {
            Toast.show(message: "Cancelled.", detail: "Nothing was saved or copied.", near: target.region)
        } catch {
            Toast.show(message: "Capture failed.", detail: error.localizedDescription, near: target.region)
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
        if collectText, let root = target.textRoot { driver.collector = TextCollector(root: root, region: target.region, bundleID: target.bundleID) }
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

    /// Why a pane with a text area was screenshotted instead, for the pop-up (nil: nothing to say).
    static func whyNotText(_ v: SharedTextCheck.Verdict) -> String? {
        switch v {
        case .complete: nil
        case .notText: "no text area here (the app doesn't share this pane as text)."
        case .empty: "the app shared no text."
        case .doesntFillPane: "the text area the app shared doesn't fill the pane."
        case .inWebPage: "this app shares only the text on screen."
        case .truncated: "the app's text was cut short."
        case .cantTell: "the app didn't show its text was complete."
        }
    }

    /// A text capture: the app's text saved and copied, with no scrolling and no pictures.
    private func deliverText(_ doc: ExportDocument, target: CaptureTarget, baseName: String,
                             modeLine: String = "Text capture: read from the app, no scrolling.") async {
        let outcome = await Delivery.deliverText(doc, settings: settings, baseName: baseName)
        if settings.shutterSound { NSSound(named: "Pop")?.play() }
        let lines = PlainTextDocument.lineCount(doc)
        var detail = [modeLine]
        if let line = Delivery.exportsLine(outcome) { detail.append(line) }
        detail += outcome.notes
        if let e = outcome.error { detail.insert(e, at: 0) }
        guard settings.showToast || outcome.error != nil else { Toast.hide(); return }
        Toast.show(message: Delivery.message(outcome), detail: detail.joined(separator: "\n"),
                   heightBadge: "\(Delivery.number(lines)) \(lines == 1 ? "line" : "lines")", file: outcome.file, near: target.region)
    }

    private func deliver(_ result: CaptureResult, capturer: WindowCapturer, target: CaptureTarget, text: ExportDocument?, baseName: String,
                         mode: String = "Scrolling screenshot.") async {
        let slow = settings.savePDF || settings.saveDOCX || settings.saveMarkdown || settings.needsText
        if slow { Toast.show(message: "Making the files…", detail: settings.savePDF ? "Reading the text for the PDF on this Mac." : nil, near: target.region, seconds: 30) }
        let outcome = await Delivery.deliver(result.image, colorSpace: capturer.colorSpace, settings: settings, accessibilityText: text, baseName: baseName)
        if settings.shutterSound { NSSound(named: "Pop")?.play() }
        var (message, detail) = Self.popUpText(result, saved: Delivery.message(outcome))
        var extra: [String] = []
        if let line = Delivery.exportsLine(outcome) { extra.append(line) }
        if let src = outcome.textSource, settings.needsText { extra.append(src.note) }
        extra += outcome.notes
        // Which mode ran comes first.
        detail = ([mode] + [detail].compactMap { $0 } + extra).joined(separator: "\n")
        if DiagnosticsWriter.shouldWrite(settingOn: settings.keepDiagnostics, result: result) {
            let folder = settings.diagnosticsFolder ?? outcome.file?.deletingLastPathComponent() ?? settings.folderURL
            let base = outcome.file.map { $0.deletingPathExtension().lastPathComponent } ?? baseName
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

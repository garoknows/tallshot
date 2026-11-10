import CoreGraphics
import Testing
@testable import TallshotCore

/// A text view that fills a 600 × 400 pane.
private let pane = CGRect(x: 100, y: 100, width: 600, height: 400)

private func facts(_ text: String, role: String = "AXTextArea", web: Bool = false, count: Int? = nil, visible: Range<Int>? = nil,
                   frame: CGRect = CGRect(x: 100, y: -2_000, width: 600, height: 6_000)) -> SharedTextFacts {
    SharedTextFacts(role: role, insideWebPage: web, text: text, characterCount: count ?? text.utf16.count, visibleRange: visible,
                    frame: frame, region: pane)
}

private func lines(_ n: Int) -> String { (1...n).map { "line \($0)" }.joined(separator: "\n") }

@Suite("Text capture: is the shared text complete?")
struct SharedTextCheckTests {
    @Test func aTextViewThatReportsMoreThanIsVisibleIsComplete() {
        let t = lines(500)
        #expect(SharedTextCheck.verdict(facts(t, visible: 1_200..<2_000)) == .complete)
        // Scrolled to the very top: the rest is below.
        #expect(SharedTextCheck.verdict(facts(t, visible: 0..<800)) == .complete)
    }

    @Test func aTerminalWithoutAVisibleRangeIsCompleteWhenItHasMoreLinesThanFit() {
        // Ghostty-like: one text area the size of the pane, a long history, no visible range.
        let f = facts(lines(2_000), frame: pane)
        #expect(SharedTextCheck.verdict(f) == .complete)
    }

    @Test func textThatCouldAllBeOnScreenIsNotTrusted() {
        // It may be only what's visible: scroll instead.
        #expect(SharedTextCheck.verdict(facts(lines(20), frame: pane)) == .cantTell)
        let t = lines(20)
        #expect(SharedTextCheck.verdict(facts(t, visible: 0..<t.utf16.count, frame: pane)) == .cantTell)
    }

    @Test func browsersAndElectronAppsAreNeverTrusted() {
        #expect(SharedTextCheck.verdict(facts(lines(5_000), web: true, visible: 0..<100)) == .inWebPage)
    }

    @Test func otherRolesAreNotText() {
        for role in ["AXWebArea", "AXScrollArea", "AXTextField", "AXGroup", "AXList"] {
            #expect(SharedTextCheck.verdict(facts(lines(500), role: role, visible: 0..<100)) == .notText)
        }
    }

    @Test func textCutShortIsNotComplete() {
        let t = lines(500)
        #expect(SharedTextCheck.verdict(facts(t, count: t.utf16.count + 10_000, visible: 0..<100)) == .truncated)
    }

    @Test func aMessageBoxIsNotThePane() {
        let box = CGRect(x: 120, y: 440, width: 560, height: 50)
        #expect(SharedTextCheck.verdict(facts(lines(500), visible: 0..<100, frame: box)) == .doesntFillPane)
    }

    @Test func emptyTextIsNotCopied() {
        #expect(SharedTextCheck.verdict(facts("  \n\n \t", visible: 0..<1)) == .empty)
    }
}

@Suite("Text capture: the document made from the text")
struct PlainTextDocumentTests {
    @Test func aTerminalKeepsItsExactSpacingAsOneCodeBlock() {
        let text = "$ ls -l\n  total 8\n-rw-r--r--  1 me  staff  12 notes.txt\n\n    indented\n"
        let doc = PlainTextDocument.document(from: text, preformatted: PlainTextDocument.isPreformatted(bundleID: "com.mitchellh.ghostty", text: text))
        #expect(doc.blocks == [.code("$ ls -l\n  total 8\n-rw-r--r--  1 me  staff  12 notes.txt\n\n    indented")])
        let md = Markdown.render(doc)
        #expect(md.contains("```\n$ ls -l\n  total 8\n"))
    }

    @Test func codeContainingFencesStaysInsideItsBlock() {
        let doc = PlainTextDocument.document(from: "a\n```\nb", preformatted: true)
        let md = Markdown.render(doc)
        #expect(md.contains("````\na\n```\nb\n````"))
    }

    @Test func proseBecomesParagraphsAndBullets() {
        let doc = PlainTextDocument.document(from: "Trip plan\n\n• Passport\n- Tickets\nCall the hotel", preformatted: false)
        #expect(doc.blocks == [.paragraph([Inline("Trip plan")]), .listItem(level: 0, ordered: false, [Inline("Passport")]),
                               .listItem(level: 0, ordered: false, [Inline("Tickets")]), .paragraph([Inline("Call the hotel")])])
    }

    @Test func indentedOrBoxDrawnTextCountsAsPreformatted() {
        #expect(PlainTextDocument.isPreformatted(bundleID: nil, text: "func a() {\n    b()\n    c()\n}"))
        #expect(PlainTextDocument.isPreformatted(bundleID: nil, text: "┌──┐\n│ok│\n└──┘"))
        #expect(!PlainTextDocument.isPreformatted(bundleID: "com.apple.Notes", text: "Dear Sam,\nThanks for the books.\nSee you soon."))
    }

    @Test func controlCharactersAndLineEndingsAreCleaned() {
        #expect(PlainTextDocument.clean("\n\na\u{0}b\r\nc  \rd\t\u{1B}\n\n") == "ab\nc\nd")
    }

    @Test func linesAreCountedForThePopUp() {
        #expect(PlainTextDocument.lineCount(PlainTextDocument.document(from: lines(1_204), preformatted: true)) == 1_204)
        #expect(PlainTextDocument.lineCount(PlainTextDocument.document(from: "a\nb\n\nc", preformatted: false)) == 3)
    }
}

/// A simulated window that records where the page went, and can fail.
@MainActor
final class RecordingWindow: CaptureDriver {
    let window: SimulatedWindow
    var positions: [Int] = []
    var failAfterCaptures: Int?
    private var captures = 0
    struct Broke: Error {}

    init(_ window: SimulatedWindow) { self.window = window }
    func captureFrame() async throws -> PixelImage {
        captures += 1
        if let f = failAfterCaptures, captures > f { throw Broke() }
        return try await window.captureFrame()
    }
    func scroll(pixels: Int) async throws { try await window.scroll(pixels: pixels); positions.append(window.pos) }
    func pause(milliseconds: Int) async { await window.pause(milliseconds: milliseconds) }
    var isCancelled: Bool { window.isCancelled }
    var now: Double { window.now }
    func reverseScrollDirection() { window.reverseScrollDirection() }
    func setScrollMethod(_ method: ScrollMethod) -> Bool { window.setScrollMethod(method) }
    func contentSettled() { window.contentSettled() }
}

@Suite("The pointer always comes back", .serialized)
@MainActor
struct PointerParkingTests {
    final class Mouse {
        var at = CGPoint(x: 5, y: 5)
        var moves: [CGPoint] = []
    }

    func parking(_ m: Mouse) -> PointerParking {
        PointerParking(move: { m.at = $0; m.moves.append($0) }, location: { m.at })
    }

    func capture(_ driver: CaptureDriver, _ parking: PointerParking, userMoved: Bool = false) async throws -> CaptureResult {
        try await parking.whileParked(at: CGPoint(x: 300, y: 300), userMoved: { userMoved }) {
            try await CaptureSession(driver: driver, options: CaptureOptions()).run()
        }
    }

    @Test func afterAFinishedCapture() async throws {
        let m = Mouse(), p = parking(m)
        let r = try await capture(SimulatedWindow(pageHeight: 1_600), p)
        #expect(r.reason == .bottom)
        #expect(m.at == CGPoint(x: 5, y: 5) && !p.isParked)
        #expect(m.moves == [CGPoint(x: 300, y: 300), CGPoint(x: 5, y: 5)], "parked once, back once, each a real move")
    }

    @Test func afterEsc() async throws {
        let m = Mouse(), p = parking(m)
        let w = SimulatedWindow(pageHeight: 3_000)
        w.cancelAfterCaptures = 3
        let r = try await capture(w, p)
        #expect(r.reason == .cancelled)
        #expect(m.at == CGPoint(x: 5, y: 5) && !p.isParked)
    }

    @Test func afterAnError() async {
        let m = Mouse(), p = parking(m)
        let d = RecordingWindow(SimulatedWindow(pageHeight: 3_000))
        d.failAfterCaptures = 4
        await #expect(throws: RecordingWindow.Broke.self) { _ = try await capture(d, p) }
        #expect(m.at == CGPoint(x: 5, y: 5) && !p.isParked)
    }

    @Test func afterAnEarlyStop() async throws {
        let m = Mouse(), p = parking(m)
        var o = CaptureOptions()
        o.maxHeight = 900
        let r = try await p.whileParked(at: CGPoint(x: 300, y: 300), userMoved: { false }) {
            try await CaptureSession(driver: SimulatedWindow(pageHeight: 5_000), options: o).run()
        }
        #expect(r.reason == .heightCap)
        #expect(m.at == CGPoint(x: 5, y: 5) && !p.isParked)
    }

    @Test func whereTheUserPutItIfTheyMovedIt() async throws {
        let m = Mouse(), p = parking(m)
        p.park(at: CGPoint(x: 300, y: 300))
        m.at = CGPoint(x: 900, y: 40)   // the user moved the mouse
        p.restore(userMoved: true)
        #expect(m.at == CGPoint(x: 900, y: 40))
        #expect(m.moves.last == CGPoint(x: 900, y: 40), "still a mouse-moved there, so the pointer's shape is refreshed")
        p.restore(userMoved: false)
        #expect(m.moves.count == 2, "a second restore does nothing")
    }
}

@Suite("Why Ghostty began scrolling in 1.0")
@MainActor
struct TerminalAtTheBottomTests {
    /// A terminal sits at the bottom of its history, so the first scroll down moves nothing. Since
    /// 1.0 the engine then tries the other direction once (in case scrolling is reversed), which
    /// scrolls the terminal up, sees it went the wrong way, and scrolls back. 0.2.3 gave up at once.
    @Test func aPaneAtItsBottomIsScrolledUpAndBackByTheDirectionCheck() async throws {
        let w = SimulatedWindow(pageHeight: 3_000)
        w.pos = w.maxPos
        let d = RecordingWindow(w)
        let r = try await CaptureSession(driver: d, options: CaptureOptions()).run()
        #expect(d.positions.contains { $0 < w.maxPos }, "the direction check scrolled up")
        #expect(w.pos == w.maxPos, "and back down")
        #expect(r.reason.isEarly)
    }
}

@Suite("Three hotkeys never share keys")
struct HotkeySlotTests {
    @Test func sameKeysAreFound() {
        let a = HotkeyConflicts.Keys(keyCode: 17, modifiers: HotkeyConflicts.hyper)
        let b = HotkeyConflicts.Keys(keyCode: 34, modifiers: HotkeyConflicts.hyper)
        #expect(HotkeyConflicts.sameKeys(as: 3, in: [1: a, 2: b, 3: a]) == 1)
        #expect(HotkeyConflicts.sameKeys(as: 3, in: [1: a, 2: b, 3: b]) == 2)
        #expect(HotkeyConflicts.sameKeys(as: 3, in: [1: a, 2: b]) == nil)
        #expect(HotkeyConflicts.sameKeys(as: 2, in: [1: a, 2: b]) == nil)
    }
}

@Suite("After every capture the pointer is reset", .serialized)
@MainActor
struct PointerResetTests {
    /// A pretend keyboard and app: Option is held for `heldFor` seconds of the pretend clock.
    /// The app shows a crosshair while it believes Option is down (as Ghostty does), and only
    /// redraws the pointer when the mouse moves.
    final class Desk {
        var clock = 0.0
        var heldFor: Double
        var appThinksOptionDown = true
        var pointer = "crosshair"
        var log: [String] = []
        init(heldFor: Double) { self.heldFor = heldFor }
        var held: Bool { clock < heldFor }
    }

    func reset(_ d: Desk) async -> Bool {
        await PointerReset.run(modifiersHeld: { d.held }, now: { d.clock }, sleep: { d.clock += Double($0) / 1000 },
                               sendModifierKeyUps: { d.log.append("key-ups"); d.appThinksOptionDown = false },
                               sendMouseMove: { d.log.append("move"); d.pointer = d.appThinksOptionDown ? "crosshair" : "arrow" })
    }

    @Test func theCrosshairBecomesTheArrowOnceTheKeysAreUp() async {
        let d = Desk(heldFor: 0.7)   // the user lets go of ⌃⌥⇧⌘ a moment after the capture
        #expect(await reset(d))
        #expect(d.log == ["key-ups", "move"], "key-ups only after the keys are really up, then a move")
        #expect(d.clock >= 0.7)
        #expect(d.pointer == "arrow")
    }

    @Test func aTextCaptureRightAfterTheHotkeyStillEndsWithTheArrow() async {
        // A text capture finishes in a moment, while the hotkey's keys are still down.
        let d = Desk(heldFor: 2.5)
        #expect(await reset(d))
        #expect(d.pointer == "arrow")
    }

    @Test func keysHeldTooLongAreLeftAlone() async {
        let d = Desk(heldFor: 60)
        #expect(await reset(d) == false)
        #expect(d.log == ["move"], "no fake key-up for a key the user is still holding")
        #expect(d.clock >= 10 && d.clock < 11)
    }

    @Test func withNoKeysHeldItIsImmediate() async {
        let d = Desk(heldFor: 0)
        #expect(await reset(d))
        #expect(d.clock == 0 && d.pointer == "arrow")
    }
}

@Suite("The version line")
struct AppVersionTests {
    @Test func itComesFromTheInfoPlist() {
        #expect(AppVersion.title(info: ["CFBundleShortVersionString": "1.1.1"]) == "Tallshot 1.1.1")
        #expect(AppVersion.title(info: ["CFBundleShortVersionString": " 2.0.0 \n"]) == "Tallshot 2.0.0")
        #expect(AppVersion.title(info: [:]) == "Tallshot")
        #expect(AppVersion.title(info: nil) == "Tallshot")
    }

    @Test func releaseNotesIsTheReleasesPage() {
        #expect(AppVersion.releaseNotesAddress == "https://github.com/garoknows/tallshot/releases")
    }
}

@Suite("A refused hotkey names the likely screenshot app")
struct HotkeyClashTests {
    @Test func shottrIsNamedWhenItIsRunning() {
        let m = HotkeyConflicts.refusedMessage(display: "⌃⌥⇧⌘X", running: ["cc.ffitch.shottr", "com.apple.finder"])
        #expect(m.contains("macOS refused ⌃⌥⇧⌘X") && m.contains("Shottr is running and is the likely one"))
        let both = HotkeyConflicts.refusedMessage(running: ["cc.ffitch.shottr", "pl.maketheweb.cleanshotx"])
        #expect(both.contains("Shottr or CleanShot X"))
        #expect(!HotkeyConflicts.refusedMessage(running: ["com.apple.finder"]).contains("likely"))
        #expect(HotkeyConflicts.warning(keyCode: 7, modifiers: HotkeyConflicts.hyper, registered: false, systemTaken: false,
                                        running: ["cc.ffitch.shottr"])?.contains("Shottr") ?? false)
    }
}

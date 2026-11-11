import CoreGraphics

/// What an app reports, through Accessibility, about the text element under the pointer.
public struct SharedTextFacts: Sendable, Equatable {
    /// The element's role, such as "AXTextArea".
    public var role: String
    /// True when the element sits inside a web page (a browser, or an Electron app such as a chat
    /// app or VS Code). Web pages usually share only the part that's on screen.
    public var insideWebPage: Bool
    /// The element's whole value, as the app shares it.
    public var text: String
    /// How many characters the app says the element holds (`AXNumberOfCharacters`), if it says.
    public var characterCount: Int?
    /// The characters on screen (`AXVisibleCharacterRange`, in UTF-16 units), if the app says.
    public var visibleRange: Range<Int>?
    /// The element's frame and the pane being captured, in screen points.
    public var frame: CGRect
    public var region: CGRect
    /// The element was found right under the middle of the pane (so it is the pane's text even
    /// when the app reports no usable frame).
    public var underPaneCenter: Bool

    public init(role: String, insideWebPage: Bool, text: String, characterCount: Int?, visibleRange: Range<Int>?,
                frame: CGRect, region: CGRect, underPaneCenter: Bool = false) {
        self.role = role; self.insideWebPage = insideWebPage; self.text = text
        self.characterCount = characterCount; self.visibleRange = visibleRange
        self.frame = frame; self.region = region; self.underPaneCenter = underPaneCenter
    }
}

/// Decides whether the text an app shares is the pane's complete contents, so Tallshot can copy
/// it instead of scrolling. When in doubt the answer is no, and Tallshot takes a scrolling
/// screenshot as before: copying only part of a document would be worse than scrolling.
public enum SharedTextCheck {
    public enum Verdict: Equatable, Sendable {
        /// The whole text, including what's scrolled out of view.
        case complete
        /// Not a document's text (a list, a page, a button...).
        case notText
        /// Inside a web page: browsers and Electron apps share only what's on screen.
        case inWebPage
        case empty
        /// The app's character count doesn't match the text it gave: it was cut short.
        case truncated
        /// A small text box (a message field), not the pane.
        case doesntFillPane
        /// Nothing shows the text goes beyond the screen, so it may be only what's visible.
        case cantTell

        public var isComplete: Bool { self == .complete }
    }

    /// Lines can't be shorter than this many points, so more lines than fit in the pane at this
    /// height prove the text reaches beyond what's on screen.
    public static let minimumLineHeight: CGFloat = 8

    public static func verdict(_ f: SharedTextFacts) -> Verdict {
        guard f.role == "AXTextArea" else { return .notText }
        guard !f.insideWebPage else { return .inWebPage }
        guard f.text.contains(where: { !$0.isWhitespace }) else { return .empty }
        let total = f.text.utf16.count
        // Cut short: the app says it holds more than it gave. Apps count in different units
        // (UTF-16, Unicode characters, letters), so only a count above all of them counts.
        if let n = f.characterCount, n > max(total, f.text.unicodeScalars.count, f.text.count) { return .truncated }
        // The element must be the pane, not a box inside it: it covers at least half of it. An
        // element with no frame is accepted if it was found under the middle of the pane.
        let overlap = f.frame.intersection(f.region)
        let regionArea = f.region.width * f.region.height
        let fills = !overlap.isNull && regionArea > 0 && overlap.width * overlap.height >= regionArea * 0.5
        let noFrame = f.frame.width < 1 || f.frame.height < 1
        guard fills || (noFrame && f.underPaneCenter) else { return .doesntFillPane }
        // Proof that the text includes what's scrolled out of view, without moving anything:
        // more lines than could ever fit in the pane, or a visible range smaller than the whole.
        let lines = f.text.split(separator: "\n", omittingEmptySubsequences: false).count
        if CGFloat(lines) > f.region.height / minimumLineHeight { return .complete }
        if let visible = f.visibleRange, visible.lowerBound > 0 || visible.upperBound < total { return .complete }
        return .cantTell
    }
}

/// Turns text an app shares into a document for the Markdown, Word and PDF exports.
public enum PlainTextDocument {
    /// Terminals and code editors: their text keeps its exact spacing, as one code block.
    public static let monospacedApps: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper", "com.apple.dt.Xcode", "com.barebones.bbedit",
        "com.sublimetext.3", "com.sublimetext.4", "com.panic.Nova", "com.coteditor.CotEditor", "dev.zed.Zed", "com.macromates.TextMate",
    ]

    /// Whether the text should keep its exact spacing: a terminal or code editor, or text whose
    /// lines are mostly indented or drawn with box characters.
    public static func isPreformatted(bundleID: String?, text: String) -> Bool {
        if let id = bundleID, monospacedApps.contains(id) { return true }
        let lines = text.split(separator: "\n").filter { $0.contains { !$0.isWhitespace } }
        guard lines.count >= 3 else { return false }
        let shaped = lines.filter { l in
            l.hasPrefix("  ") || l.hasPrefix("\t") || l.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
        }
        return Double(shaped.count) / Double(lines.count) >= 0.3
    }

    /// The text with Windows and old Mac line endings made "\n", control characters removed (tabs
    /// kept), spaces at line ends removed, and blank lines at the start and end dropped.
    public static func clean(_ text: String) -> String {
        let unified = text.replacingAll("\r\n", with: "\n").replacingAll("\r", with: "\n")
        let kept = String(String.UnicodeScalarView(unified.unicodeScalars.filter { s in
            s == "\n" || s == "\t" || !(s.value < 0x20 || (0x7F...0x9F).contains(s.value))
        }))
        var lines = kept.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
            return String(l)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The document: one code block for preformatted text, else a paragraph per line, with lines
    /// that start with a bullet as list items.
    public static func document(from text: String, preformatted: Bool) -> ExportDocument {
        let t = clean(text)
        let blocks: [Block] = preformatted ? (t.isEmpty ? [] : [.code(t)]) : prose(t)
        return ExportDocument(blocks: blocks, source: .accessibility)
    }

    /// Paragraphs and bullet items from plain text (also used for a document view's text while
    /// scrolling). A blank line ends a paragraph; the lines of one paragraph stay one paragraph,
    /// with their line breaks, so Markdown doesn't get a blank line after every line. A line that
    /// starts with a bullet is a list item.
    public static func prose(_ text: String) -> [Block] {
        var out: [Block] = [], lines: [String] = []
        func flush() {
            if !lines.isEmpty { out.append(.paragraph([Inline(lines.joined(separator: "\n"))])) }
            lines = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(raw)
            while let last = line.last, last == " " || last == "\t" || last == "\r" { line = line.dropLast() }
            let t = String(line)
            if t.trimmingWhitespace.isEmpty { flush(); continue }
            if let first = t.first, "•◦▪-–*".contains(first) {
                flush()
                out.append(.listItem(level: 0, ordered: false, [Inline(String(t.dropFirst()).trimmingWhitespace)]))
            } else {
                lines.append(t)
            }
        }
        flush()
        return out
    }

    /// Lines of text, for the pop-up ("1,204 lines").
    public static func lineCount(_ doc: ExportDocument) -> Int {
        doc.blocks.reduce(0) { n, b in
            if case .code(let c, _) = b { return n + c.split(separator: "\n", omittingEmptySubsequences: false).count }
            return n + b.plainText.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }
}

/// Moves the pointer to where a capture scrolls, and always puts it back afterwards. Two kinds of
/// move, kept apart on purpose:
///  - `jump` (park): a silent move that tells no app anything. Used before the first picture, so
///    nothing under the pointer reacts (a hover, a scroll bar appearing) while pictures are taken.
///  - `move` (restore): a move with a real "mouse moved" event, so the app under the pointer
///    redraws it in its normal shape. Used only once the last picture is taken.
/// In 1.1.0 and 1.1.1 parking used the real move too, and the self-test failed (see DECISIONS).
/// Whatever happens in between (finished, Esc, an error, an early stop), `restore` runs once.
@MainActor
public final class PointerParking {
    let jump: @MainActor (CGPoint) -> Void
    let move: @MainActor (CGPoint) -> Void
    let location: @MainActor () -> CGPoint
    private var saved: CGPoint?

    public init(jump: @escaping @MainActor (CGPoint) -> Void, move: @escaping @MainActor (CGPoint) -> Void,
                location: @escaping @MainActor () -> CGPoint) {
        self.jump = jump
        self.move = move
        self.location = location
    }

    public var isParked: Bool { saved != nil }

    public func park(at point: CGPoint) {
        if saved == nil { saved = location() }
        jump(point)
    }

    /// Back where it was. If the user moved the pointer during the capture, it stays where they
    /// put it, but still gets a mouse-moved there so its shape is refreshed.
    public func restore(userMoved: Bool) {
        guard let s = saved else { return }
        saved = nil
        move(userMoved ? location() : s)
    }

    /// Runs `body` with the pointer parked at `point`, and restores it however `body` ends.
    public func whileParked<T>(at point: CGPoint, userMoved: () -> Bool, _ body: () async throws -> T) async rethrows -> T {
        park(at: point)
        defer { restore(userMoved: userMoved()) }
        return try await body()
    }
}

/// After every capture: wait until the hotkey's modifier keys are really let go, tell the app
/// under the pointer they're up, then give the pointer a real mouse move. Some apps change the
/// pointer while a modifier is held (Ghostty shows a crosshair while Option is down, for block
/// selection) and only change it back when they see the key go up and the mouse move.
@MainActor
public enum PointerReset {
    /// Returns true if the modifiers were let go within `timeout` seconds (then the key-ups were
    /// sent). Keys still held after that are left alone: sending a key-up for a key the user is
    /// holding would confuse the app. The mouse move is sent either way.
    @discardableResult
    public static func run(timeout: Double = 10, modifiersHeld: () -> Bool, now: () -> Double, sleep: (Int) async -> Void,
                           sendModifierKeyUps: () -> Void, sendMouseMove: () -> Void) async -> Bool {
        let start = now()
        while modifiersHeld() && now() - start < timeout { await sleep(50) }
        let released = !modifiersHeld()
        if released { sendModifierKeyUps() }
        sendMouseMove()
        return released
    }
}

/// The version line at the bottom of Settings, from the app's own Info.plist.
public enum AppVersion {
    /// "Tallshot 1.1.1", from `CFBundleShortVersionString`; "Tallshot" if it's missing.
    public static func title(info: [String: Any]?) -> String {
        guard let v = info?["CFBundleShortVersionString"] as? String, !v.trimmingWhitespace.isEmpty else { return "Tallshot" }
        return "Tallshot \(v.trimmingWhitespace)"
    }

    /// Opened in the browser by Release Notes…; Tallshot itself never connects to it.
    public static let releaseNotesAddress = "https://github.com/garoknows/tallshot/releases"
}

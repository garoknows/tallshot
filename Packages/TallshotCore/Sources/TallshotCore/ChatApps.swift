import CoreGraphics

/// What Check This App found and the user confirmed for one app: whether its accessibility tree
/// holds the whole conversation, so a capture can copy the text with no scrolling.
public struct CheckedApp: Codable, Equatable, Sendable {
    public var name: String
    public var keepsWholeConversation: Bool
    /// When it was checked, as "2026-11-10".
    public var checked: String
    public init(name: String, keepsWholeConversation: Bool, checked: String) {
        self.name = name; self.keepsWholeConversation = keepsWholeConversation; self.checked = checked
    }
}

/// Which chat apps get a text capture (the whole conversation read from the app, no scrolling)
/// instead of a scrolling screenshot.
public enum ChatApps {
    public struct Known: Sendable, Equatable {
        public var name: String
        public var text: Bool
    }

    /// Checked on Garo's Mac on 2026-11-10 with the accessibility probe: the ChatGPT app keeps the
    /// whole conversation (its first message was the chat's real first), the Claude app keeps only
    /// about one screen around what's visible. A check of the app replaces these.
    public static let builtIn: [String: Known] = [
        "com.openai.codex": Known(name: "ChatGPT", text: true),
        "com.anthropic.claudefordesktop": Known(name: "Claude", text: false),
    ]

    /// Whether a capture of this app copies the conversation as text.
    public static func usesText(bundleID: String?, checked: [String: CheckedApp]) -> Bool {
        guard let id = bundleID else { return false }
        if let c = checked[id] { return c.keepsWholeConversation }
        return builtIn[id]?.text ?? false
    }

    /// What a check's result window offers.
    public enum Offer: Equatable, Sendable {
        /// Much more than a screen of text: the whole conversation if its first message is the
        /// chat's real first. Only the user can see that, so they confirm.
        case confirmWholeConversation
        /// About a screen or less: the app keeps only what's near the screen, unless this chat
        /// is that short. The user can keep scrolling screenshots, or check a longer chat.
        case keepScrolling
        /// No conversation text at all: nothing to remember.
        case nothing
    }

    public static func offer(for verdict: ProbeReport.Verdict) -> Offer {
        switch verdict {
        case .beyondScreen: .confirmWholeConversation
        case .aboutAScreenful: .keepScrolling
        case .noText: .nothing
        }
    }

    /// One line per app for Settings: the checked ones, then the built-in ones not checked yet.
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var text: Bool
        /// "checked 2026-11-10" or "built in".
        public var source: String
    }

    public static func rows(checked: [String: CheckedApp]) -> [Row] {
        let mine = checked.map { Row(id: $0.key, name: $0.value.name, text: $0.value.keepsWholeConversation, source: "checked \($0.value.checked)") }
        let builtIns = builtIn.filter { checked[$0.key] == nil }.map { Row(id: $0.key, name: $0.value.name, text: $0.value.text, source: "built in") }
        return mine.sorted { $0.name < $1.name } + builtIns.sorted { $0.name < $1.name }
    }
}

/// Where a Tallshot window opens: on the display with the pointer (the one the user is working
/// on), centered a little above the middle. A window already on that display stays where it is.
public enum WindowOpening {
    public struct Screen: Sendable, Equatable {
        /// The display's whole frame and the part not under the menu bar or Dock, in AppKit
        /// coordinates (origin at the bottom left of the main display, y up).
        public var frame: CGRect
        public var visible: CGRect
        public init(frame: CGRect, visible: CGRect) { self.frame = frame; self.visible = visible }
    }

    public static func frame(size: CGSize, pointer: CGPoint, screens: [Screen], current: CGRect?) -> CGRect {
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first else {
            return current ?? CGRect(origin: .zero, size: size)
        }
        if let current, screen.frame.contains(CGPoint(x: current.midX, y: current.midY)) { return current }
        let v = screen.visible
        // Centered across; vertically a third of the spare room above (like NSWindow.center()).
        // A window taller than the display keeps its title bar on screen.
        let x = v.minX + max(0, (v.width - size.width) / 2)
        let y = size.height >= v.height ? v.maxY - size.height : v.minY + (v.height - size.height) * 2 / 3
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// The app that was in front before Tallshot's menu opened: the last other app that became
/// active. Tallshot's own windows (Settings, a result window) never count.
public struct FrontAppMemory: Sendable, Equatable {
    public private(set) var pid: Int32?
    public let own: Int32
    public init(own: Int32, front: Int32?) { self.own = own; if let front, front != own { pid = front } }

    public mutating func activated(_ p: Int32) { if p != own { pid = p } }
    public mutating func terminated(_ p: Int32) { if pid == p { pid = nil } }
}

/// Real web browsers, which Check This App never switches to text capture: each site keeps its
/// text differently, so one answer for the whole browser can't be right. An app that only opens
/// web links (the ChatGPT app does, for its own links) is not a browser; a browser also opens
/// web pages saved as files.
public enum BrowserCheck {
    public static let knownBrowsers: [String] = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "com.kagi.kagimacOS", "app.zen-browser.zen", "com.duckduckgo.macos.browser", "net.waterfox.waterfox",
        "org.torproject.torbrowser",
        "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    public static func isRealBrowser(bundleID: String?, opensWebLinks: Bool, opensWebPageFiles: Bool) -> Bool {
        if let id = bundleID, knownBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
        return opensWebLinks && opensWebPageFiles
    }
}

/// The words of Check This App's result window: about a chat when speakers were found,
/// neutral ("text") for any other app.
public struct CheckWording: Equatable, Sendable {
    public var headline: String
    public var explanation: String
    public var firstLabel: String
    public var lastLabel: String
    /// "Who said what: …", only for a chat.
    public var speakers: String?

    public init(verdict: ProbeReport.Verdict, appName: String, screens: Double, reading: ChatReading?) {
        let chat = reading?.isChat ?? false
        let what = chat ? "this chat" : "this window's text"
        let r = (screens * 10).rounded() / 10
        let n = r == r.rounded() ? "\(Int(r))" : "\(r)"
        switch verdict {
        case .beyondScreen:
            headline = "\(appName) keeps about \(n) screens of \(what), much more than fits on screen."
            explanation = chat
                ? "If the first message below is this chat's real first message (scroll to the top of the chat to compare), \(appName) keeps the whole conversation, and Tallshot can copy it as text with no scrolling."
                : "If the first text below is the real start of what this window shows (scroll to the top to compare), \(appName) keeps all of it, and Tallshot can copy it as text with no scrolling."
        case .aboutAScreenful:
            headline = "\(appName) keeps only about \(n) screen\(n == "1" ? "" : "s") of \(what)."
            explanation = chat
                ? "If this chat is longer than one screen, \(appName) keeps only what's near the screen, so Tallshot keeps taking scrolling screenshots. If the chat really is this short, close this and check a longer one."
                : "If there's more than one screen of it, \(appName) keeps only what's near the screen, so Tallshot keeps taking scrolling screenshots. If there really is this little, close this and check a longer one."
        case .noText:
            headline = "Tallshot found no text to copy in this window."
            explanation = "Open something longer in the app, click its window, then choose Check This App… again."
        }
        firstLabel = chat ? "First message" : "First text"
        lastLabel = chat ? "Last message" : "Last text"
        speakers = reading.flatMap { r in r.isChat ? "Who said what: \(r.rule.note) (\(r.userTurns) of yours, \(r.replyTurns) replies)." : nil }
    }

    /// The first turn worth showing: for a chat, the first one with a speaker (not a title or
    /// notice before your first message).
    public static func firstTurn(_ reading: ChatReading) -> ChatTurn? {
        reading.isChat ? reading.turns.first { $0.speaker != nil } : reading.turns.first
    }
}

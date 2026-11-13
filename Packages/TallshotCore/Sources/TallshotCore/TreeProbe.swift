import CoreGraphics

/// One element found while walking an app's accessibility tree, for Check This App and for a
/// chat app's text capture. The check's copied report uses only its shape (role, frame, how much
/// text it holds, class names, parent), never the text, labels or links.
public struct ProbeNode: Sendable, Equatable {
    public var role: String
    public var frame: CGRect?
    /// Characters of text the element shows itself (a static text's value), 0 for none.
    public var textLength: Int
    /// The web page's class names for it (Chromium's `AXDOMClassList`), if any.
    public var classes: [String]
    /// The parent's index in the list (parents always come before their children), nil for the root.
    public var parent: Int?
    /// A static text's value.
    public var text: String?
    /// A button's or link's label (its description, else its title).
    public var label: String?
    /// A link's address.
    public var url: String?
    /// A heading's level (1 to 6).
    public var level: Int?
    public var subrole: String?
    public var roleDescription: String?

    public init(role: String, frame: CGRect?, textLength: Int = 0, classes: [String] = [], parent: Int? = nil,
                text: String? = nil, label: String? = nil, url: String? = nil, level: Int? = nil,
                subrole: String? = nil, roleDescription: String? = nil) {
        self.role = role; self.frame = frame; self.classes = classes; self.parent = parent
        self.textLength = textLength == 0 ? (text?.count ?? 0) : textLength
        self.text = text; self.label = label; self.url = url; self.level = level
        self.subrole = subrole; self.roleDescription = roleDescription
    }
}

/// The parts of a walked tree the probe looks at.
public struct ProbeTree: Sendable {
    public let nodes: [ProbeNode]
    public let children: [[Int]]
    /// Characters of text in each element and everything inside it.
    public let textBelow: [Int]

    public init(_ nodes: [ProbeNode]) {
        self.nodes = nodes
        var children = Array(repeating: [Int](), count: nodes.count)
        for (i, n) in nodes.enumerated() { if let p = n.parent, p < i { children[p].append(i) } }
        var below = nodes.map(\.textLength)
        for i in stride(from: nodes.count - 1, through: 0, by: -1) { if let p = nodes[i].parent, p < i { below[p] += below[i] } }
        self.children = children
        self.textBelow = below
    }

    /// Every element inside `i`, in document order (depth first), `i` first.
    public func inOrder(from i: Int) -> [Int] {
        var out: [Int] = [], stack = [i]
        while let n = stack.popLast() { out.append(n); stack += children[n].reversed() }
        return out
    }

    /// The conversation's element. With `point` (the middle of the pane being captured): the
    /// scroll area under it holding the most text. Otherwise, among the scroll areas holding at
    /// least 200 characters or a tenth of the most text any holds, the widest (a sidebar of chat
    /// titles is narrow, a toolbar holds little), then the one with the most text. Else the web page holding
    /// the most text, else the root.
    public func messageArea(near point: CGPoint? = nil) -> Int {
        func mostText(_ c: [Int]) -> Int? { c.max { textBelow[$0] < textBelow[$1] } }
        let areas = nodes.indices.filter { nodes[$0].role == "AXScrollArea" && textBelow[$0] > 0 }
        if let point, let i = mostText(areas.filter { nodes[$0].frame?.contains(point) ?? false }) { return i }
        if let most = areas.map({ textBelow[$0] }).max() {
            let big = areas.filter { textBelow[$0] >= min(200, most / 10) }
            func width(_ i: Int) -> CGFloat { nodes[i].frame.map { ($0.width / 8).rounded() } ?? 0 }
            if let i = big.max(by: { width($0) != width($1) ? width($0) < width($1) : textBelow[$0] < textBelow[$1] }) { return i }
        }
        return mostText(nodes.indices.filter { nodes[$0].role == "AXWebArea" && textBelow[$0] > 0 }) ?? 0
    }

    /// The element whose children repeat once per message: inside `area`, the one with the most
    /// children that each hold at least `minText` characters.
    public func messageList(in area: Int, minText: Int = 20) -> (list: Int, messages: [Int])? {
        var best: (Int, [Int])?
        for i in inOrder(from: area) {
            let kids = children[i].filter { textBelow[$0] >= minText }
            if kids.count >= 2, kids.count > (best?.1.count ?? 0) { best = (i, kids) }
        }
        return best.map { (list: $0.0, messages: $0.1) }
    }
}

/// What the probe found: how much text the conversation's element holds compared with what fits
/// on screen, how many messages it has, and the class names that mark them. Judged from the text,
/// not from where elements say they are: web apps often report off-screen elements as on screen.
public struct ProbeReport: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        case noText = "No text found."
        case aboutAScreenful = "About a screenful of text or less: the app keeps only what's near the screen (or the conversation is short)."
        case beyondScreen = "Much more text than fits on screen: the tree reaches beyond the screen. It holds the whole conversation only if the first message below is the chat's real first message."
    }

    /// Roughly the points of pane one character of chat text takes (7 wide, 16 tall).
    public static let pointsPerCharacter: Double = 7 * 16

    public var appName: String
    public var bundleID: String
    public var areaRole: String
    public var elements: Int
    public var settledAfter: Int
    public var characters: Int
    /// How many screenfuls of text the area holds.
    public var screenfuls: Double
    public var messages: Int
    /// Class names on most messages (a message container) and on only some (likely the speaker).
    public var messageClasses: [String]
    public var varyingClasses: [(name: String, count: Int)]
    public var headings: Int, lists: Int, listItems: Int, links: Int, codeBlocks: Int
    public var cutShort: Bool
    public var verdict: Verdict
    /// How your messages were told from the replies, and how many of each (nil: not read).
    public var speakers: (rule: SpeakerRule, yours: Int, replies: Int)?
    /// Buttons with the labels that mark a turn: after yours ("Copy message", "Edit message")
    /// and after a reply ("Good response", "Bad response"...). Only these app labels are counted.
    public var userButtons: Int = 0, replyButtons: Int = 0

    public static func == (a: ProbeReport, b: ProbeReport) -> Bool { a.text == b.text }

    /// `area`: the conversation's element; `visible`: its box on screen, in points.
    public static func make(tree: ProbeTree, area: Int, visible: CGRect, appName: String, bundleID: String,
                            settledAfter: Int, cutShort: Bool, reading: ChatReading? = nil) -> ProbeReport {
        let inside = tree.inOrder(from: area)
        let chars = tree.textBelow[area]
        let capacity = max(1, Double(visible.width * visible.height) / pointsPerCharacter)
        let screens = Double(chars) / capacity
        let msgs = tree.messageList(in: area)?.messages ?? []
        var counts: [String: Int] = [:]
        for m in msgs { for c in Set(tree.nodes[m].classes) where !c.isEmpty && c.count <= 40 { counts[c, default: 0] += 1 } }
        let common = counts.filter { Double($0.value) >= Double(msgs.count) * 0.8 }.keys.sorted()
        // Classes on some messages (the speaker's mark can be on only a few of them), not on most.
        let varying = counts.filter { $0.value >= 2 && Double($0.value) < Double(msgs.count) * 0.8 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map { (name: $0.key, count: $0.value) }
        func count(_ role: String) -> Int { inside.filter { tree.nodes[$0].role == role }.count }
        let code = inside.filter { i in tree.nodes[i].role == "AXCodeStyleGroup" || tree.nodes[i].classes.contains { $0 == "code" || $0.hasPrefix("language-") } }.count
        let verdict: Verdict = chars == 0 ? .noText : (screens > 1.5 ? .beyondScreen : .aboutAScreenful)
        var r = ProbeReport(appName: appName, bundleID: bundleID, areaRole: tree.nodes[area].role, elements: tree.nodes.count,
                            settledAfter: settledAfter, characters: chars, screenfuls: screens, messages: msgs.count,
                            messageClasses: Array(common.prefix(12)), varyingClasses: Array(varying),
                            headings: count("AXHeading"), lists: count("AXList"), listItems: count("AXListItem"),
                            links: count("AXLink"), codeBlocks: code, cutShort: cutShort, verdict: verdict)
        r.speakers = reading.map { (rule: $0.rule, yours: $0.userTurns, replies: $0.replyTurns) }
        let labels = inside.filter { ChatTranscript.controlRoles.contains(tree.nodes[$0].role) }
            .map { ChatTranscript.normalized(tree.nodes[$0].label ?? "") }
        r.userButtons = labels.filter(ChatTranscript.userButtonLabels.contains).count
        r.replyButtons = labels.filter(ChatTranscript.replyButtonLabels.contains).count
        return r
    }

    /// The report as plain text, for the clipboard. Holds no text from the app: only counts and
    /// the page's class names.
    public var text: String {
        func f(_ d: Double) -> String { let r = (d * 10).rounded() / 10; return r == r.rounded() ? "\(Int(r))" : "\(r)" }
        let who = speakers.map { "\($0.rule.note); \($0.yours) of yours, \($0.replies) replies" } ?? "not read"
        return [
            "Tallshot app check (probe 3)",
            "App: \(appName) (\(bundleID)); conversation element: \(areaRole)",
            "Verdict: \(verdict.rawValue)",
            "Elements: \(elements)\(cutShort ? " (stopped at the limit: lower bounds)" : ""); the tree stopped growing after \(settledAfter) ms",
            "Text: \(characters) characters, about \(f(screenfuls)) screenfuls of this pane",
            "Messages (repeated containers): \(messages)",
            "Classes on most messages: \(messageClasses.isEmpty ? "none" : messageClasses.joined(separator: " "))",
            "Classes on some messages (speaker?): \(varyingClasses.isEmpty ? "none" : varyingClasses.map { "\($0.name) ×\($0.count)" }.joined(separator: ", "))",
            "Structure: \(headings) headings, \(lists) lists, \(listItems) list items, \(links) links, \(codeBlocks) code blocks",
            "Turn buttons: \(userButtons) after yours (Copy/Edit message), \(replyButtons) after replies (Good/Bad response...)",
            "Speaker labels: \(who)",
        ].joined(separator: "\n")
    }
}

/// Waits for a tree that's still being built: done when the element count is the same twice in a row.
public enum TreeSettling {
    public static func settled(counts: [Int]) -> Bool {
        counts.count >= 2 && counts[counts.count - 1] == counts[counts.count - 2] && counts.last! > 0
    }
}

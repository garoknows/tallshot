import CoreGraphics

/// One element found while walking an app's accessibility tree, for the accessibility probe.
/// Only its shape is kept: role, frame, how much text it holds, its class names and its parent,
/// never the text itself.
public struct ProbeNode: Sendable, Equatable {
    public var role: String
    public var frame: CGRect?
    /// Characters of text the element shows itself (a static text's value), 0 for none.
    public var textLength: Int
    /// The web page's class names for it (Chromium's `AXDOMClassList`), if any.
    public var classes: [String]
    /// The parent's index in the list (parents always come before their children), nil for the root.
    public var parent: Int?

    public init(role: String, frame: CGRect?, textLength: Int = 0, classes: [String] = [], parent: Int? = nil) {
        self.role = role; self.frame = frame; self.textLength = textLength; self.classes = classes; self.parent = parent
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

    /// The conversation's element: the scroll area holding the most text (not a toolbar, sidebar
    /// or message box, which hold little); else the web page holding the most; else the root.
    public func messageArea() -> Int {
        func best(_ role: String) -> Int? {
            nodes.indices.filter { nodes[$0].role == role && textBelow[$0] > 0 }.max { textBelow[$0] < textBelow[$1] }
        }
        return best("AXScrollArea") ?? best("AXWebArea") ?? 0
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

    public static func == (a: ProbeReport, b: ProbeReport) -> Bool { a.text == b.text }

    /// `area`: the conversation's element; `visible`: its box on screen, in points.
    public static func make(tree: ProbeTree, area: Int, visible: CGRect, appName: String, bundleID: String,
                            settledAfter: Int, cutShort: Bool) -> ProbeReport {
        let inside = tree.inOrder(from: area)
        let chars = tree.textBelow[area]
        let capacity = max(1, Double(visible.width * visible.height) / pointsPerCharacter)
        let screens = Double(chars) / capacity
        let msgs = tree.messageList(in: area)?.messages ?? []
        var counts: [String: Int] = [:]
        for m in msgs { for c in Set(tree.nodes[m].classes) where !c.isEmpty && c.count <= 40 { counts[c, default: 0] += 1 } }
        let common = counts.filter { Double($0.value) >= Double(msgs.count) * 0.8 }.keys.sorted()
        let varying = counts.filter { Double($0.value) >= Double(msgs.count) * 0.2 && Double($0.value) < Double(msgs.count) * 0.8 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map { (name: $0.key, count: $0.value) }
        func count(_ role: String) -> Int { inside.filter { tree.nodes[$0].role == role }.count }
        let code = inside.filter { i in tree.nodes[i].role == "AXCodeStyleGroup" || tree.nodes[i].classes.contains { $0 == "code" || $0.hasPrefix("language-") } }.count
        let verdict: Verdict = chars == 0 ? .noText : (screens > 1.5 ? .beyondScreen : .aboutAScreenful)
        return ProbeReport(appName: appName, bundleID: bundleID, areaRole: tree.nodes[area].role, elements: tree.nodes.count,
                           settledAfter: settledAfter, characters: chars, screenfuls: screens, messages: msgs.count,
                           messageClasses: Array(common.prefix(12)), varyingClasses: varying,
                           headings: count("AXHeading"), lists: count("AXList"), listItems: count("AXListItem"),
                           links: count("AXLink"), codeBlocks: code, cutShort: cutShort, verdict: verdict)
    }

    /// The report as plain text, for the clipboard. Holds no text from the app: only counts and
    /// the page's class names.
    public var text: String {
        func f(_ d: Double) -> String { let r = (d * 10).rounded() / 10; return r == r.rounded() ? "\(Int(r))" : "\(r)" }
        return [
            "Tallshot accessibility probe 2",
            "App: \(appName) (\(bundleID)); conversation element: \(areaRole)",
            "Verdict: \(verdict.rawValue)",
            "Elements: \(elements)\(cutShort ? " (stopped at the limit: lower bounds)" : ""); the tree stopped growing after \(settledAfter) ms",
            "Text: \(characters) characters, about \(f(screenfuls)) screenfuls of this pane",
            "Messages (repeated containers): \(messages)",
            "Classes on most messages: \(messageClasses.isEmpty ? "none" : messageClasses.joined(separator: " "))",
            "Classes on some messages (speaker?): \(varyingClasses.isEmpty ? "none" : varyingClasses.map { "\($0.name) ×\($0.count)" }.joined(separator: ", "))",
            "Structure: \(headings) headings, \(lists) lists, \(listItems) list items, \(links) links, \(codeBlocks) code blocks",
        ].joined(separator: "\n")
    }
}

/// Waits for a tree that's still being built: done when the element count is the same twice in a row.
public enum TreeSettling {
    public static func settled(counts: [Int]) -> Bool {
        counts.count >= 2 && counts[counts.count - 1] == counts[counts.count - 2] && counts.last! > 0
    }
}

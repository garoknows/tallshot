import CoreGraphics

/// Who said something in a chat.
public enum Speaker: String, Sendable, Equatable {
    case user, assistant
}

/// How Tallshot told the user's messages from the replies.
public enum SpeakerRule: String, Sendable, Equatable {
    /// The app labels each turn for screen readers: "You said:", "ChatGPT said:".
    case labels
    /// The page marks the user's messages with a class (ChatGPT: `group/user-message`,
    /// `rich-text-user-turn`).
    case classes
    /// The user's messages are followed by their own buttons ("Copy message", "Edit message"), the
    /// replies by others ("Good response", "Bad response").
    case buttons
    /// The user's messages sit on the right in narrower bubbles.
    case layout
    /// Nothing tells them apart: the text has no speaker labels.
    case none

    public var note: String {
        switch self {
        case .labels: "from the app's own \"You said:\" labels"
        case .classes: "from the page's marks on your messages"
        case .buttons: "from the Copy message and Edit message buttons under your messages"
        case .layout: "from the layout (your messages sit on the right)"
        case .none: "none: the app doesn't show who said what"
        }
    }
}

/// One turn of a chat: a speaker (nil before the first message of the user's, or when the app
/// doesn't show speakers) and what they said.
public struct ChatTurn: Equatable, Sendable {
    public var speaker: Speaker?
    public var blocks: [Block]
    public init(speaker: Speaker?, blocks: [Block]) { self.speaker = speaker; self.blocks = blocks }
}

/// A whole conversation (or any app's text) read from an app's accessibility tree.
public struct ChatReading: Equatable, Sendable {
    public var turns: [ChatTurn]
    public var rule: SpeakerRule

    public var userTurns: Int { turns.filter { $0.speaker == .user }.count }
    public var replyTurns: Int { turns.filter { $0.speaker == .assistant }.count }
    public var hasText: Bool { turns.contains { $0.blocks.contains { !$0.plainText.trimmingWhitespace.isEmpty } } }
    /// Speakers were found: this is a chat.
    public var isChat: Bool { rule != .none }
}

/// Reads a chat app's whole conversation from its accessibility tree (every message, including
/// those scrolled out of view: only used for apps whose tree holds the whole conversation), with
/// headings, paragraphs, lists, tables, links and code blocks, and who said each part. The app's
/// own interface (skip links, navigation, status messages, "can make mistakes" notices) is left
/// out. Pure: the app's `TreeWalker` collects the tree, this turns it into turns.
public enum ChatTranscript {
    /// Buttons that close the user's turn, and buttons that close a reply (labels in lowercase).
    public static let userButtonLabels: Set<String> = ["copy message", "edit message"]
    public static let replyButtonLabels: Set<String> = ["good response", "bad response", "copy response", "regenerate response",
                                                        "regenerate", "read aloud", "more actions", "share"]
    /// Buttons inside a message (a long message of yours folds behind "Show more"): never a
    /// boundary between messages.
    public static let inMessageButtonLabels: Set<String> = ["show more", "show less"]

    static let controlRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
                                            "AXDisclosureTriangle", "AXIncrementor"]
    /// Not content: left out with everything inside them. The message box (a text area) too.
    static let skipRoles: Set<String> = ["AXTextField", "AXTextArea", "AXToolbar", "AXMenu", "AXMenuBar", "AXMenuItem",
                                         "AXScrollBar", "AXSlider", "AXTabGroup", "AXImage", "AXComboBox", "AXSearchField",
                                         "AXSplitter", "AXColumn"]
    /// Navigation, the page footer and announcements for screen readers ("Newest document
    /// available to open — press Tab…"): the app's interface, not the conversation.
    static let skipSubroles: Set<String> = ["AXLandmarkNavigation", "AXLandmarkContentInfo", "AXLandmarkSearch",
                                            "AXApplicationStatus", "AXApplicationAlert", "AXApplicationTimer", "AXApplicationMarquee"]
    static let inlineRoles: Set<String> = ["AXStaticText", "AXLink"]

    /// Interface text that is never part of a conversation (whole blocks, compared in lowercase).
    public static let interfaceText: Set<String> = ["skip to content", "skip to main content", "latest response",
                                                    "jump to latest", "scroll to bottom"]

    /// Whether a whole block is the app's interface rather than the conversation: a known string,
    /// a "… can make mistakes" notice, or a keyboard hint for screen readers.
    public static func isInterfaceText(_ text: String) -> Bool {
        let t = text.trimmingWhitespace.lowercased()
        if interfaceText.contains(t) { return true }
        guard t.count <= 160 else { return false }
        let words = t.split(separator: " ")
        if words.count >= 4, words.prefix(4).joined(separator: " ").contains("can make mistakes") { return true }
        return t.contains("— press tab") || t.contains("- press tab") || t.hasPrefix("press tab to")
    }

    /// "You said:" → the user; "ChatGPT said:" → a reply. Screen-reader labels before each turn.
    public static func turnLabel(_ text: String) -> Speaker? {
        let t = text.trimmingWhitespace.lowercased()
        guard t.count <= 48 else { return nil }
        let name: Substring
        if t.hasSuffix(" said:") { name = t.dropLast(6) } else if t.hasSuffix(" said") { name = t.dropLast(5) } else { return nil }
        guard !name.isEmpty, !name.contains(":") else { return nil }
        return name == "you" ? .user : .assistant
    }

    /// A class that marks the user's own message: `group/user-message`, `rich-text-user-turn`,
    /// `_userBubble_…`, `human-turn`. Not a navigation rail that lists them.
    public static func isUserClass(_ c: String) -> Bool {
        let letters = String(c.lowercased().filter(\.isLetter))
        guard !letters.contains("navigation"), !letters.contains("rail") else { return false }
        return ["usermessage", "userturn", "userbubble", "humanmessage", "humanturn"].contains { letters.contains($0) }
    }

    public static func normalized(_ label: String) -> String { label.trimmingWhitespace.lowercased() }

    /// The conversation inside `area`.
    public static func read(tree: ProbeTree, area: Int) -> ChatReading {
        var pieces: [Piece] = []
        walk(tree, area, user: false, into: &pieces)
        return speakers(withoutRepeats(pieces))
    }

    /// The document for the exports: "You" and the app's name before each turn.
    public static func document(_ reading: ChatReading, assistantName: String) -> ExportDocument {
        var blocks: [Block] = []
        for turn in reading.turns {
            if let s = turn.speaker { blocks.append(.speaker(s == .user ? "You" : assistantName)) }
            blocks += turn.blocks
        }
        return ExportDocument(blocks: blocks, source: .accessibility)
    }

    // MARK: The tree, in order: blocks of content, the buttons between them, turn labels

    enum Piece: Equatable {
        case block(Block, user: Bool, frame: CGRect?)
        case control(String)
        /// A "You said:" / "ChatGPT said:" label: who says the blocks that follow.
        case mark(Speaker)
    }

    static func text(_ n: ProbeNode) -> String? { n.text.map(HTMLEntities.decode) }

    static func walk(_ t: ProbeTree, _ i: Int, user inherited: Bool, into out: inout [Piece]) {
        let n = t.nodes[i]
        let user = inherited || n.classes.contains(where: isUserClass)
        if controlRoles.contains(n.role) {
            let label = n.label.map(\.trimmingWhitespace).flatMap { $0.isEmpty ? nil : $0 } ?? joined(inlines(t, i, insideControl: true))
            out.append(.control(label))
            return
        }
        if skipRoles.contains(n.role) || n.subrole.map(skipSubroles.contains) == true { return }
        func emit(_ b: Block) {
            let plain = b.plainText
            if let s = turnLabel(plain) { out.append(.mark(s)); return }
            if isInterfaceText(plain) { return }
            out.append(.block(b, user: user, frame: n.frame))
        }
        if n.role == "AXHeading" || isHeadingClass(t, i) {
            let text = joined(inlines(t, i)).trimmingWhitespace
            if !text.isEmpty { emit(.heading(level: headingLevel(t, i), [Inline(text)])) }
            return
        }
        if n.role == "AXList" {
            var items: [Block] = []
            list(t, i, depth: 0, into: &items)
            items.forEach(emit)
            return
        }
        if let rows = table(t, i) {
            if !rows.isEmpty { emit(.table(rows)) }
            return
        }
        if isCodeBlock(t, i) {
            let code = codeText(t, i)
            if !code.trimmingWhitespace.isEmpty { emit(.code(code, language: codeLanguage(t, i))) }
            return
        }
        if isInlineRun(t, i) {
            let spans = trimmed(inlines(t, i))
            if !spans.isEmpty { emit(.paragraph(spans)) }
            return
        }
        for k in t.children[i] { walk(t, k, user: user, into: &out) }
    }

    /// A heading the page draws as a plain element with a heading class (`_Heading_xjxw3_2`).
    static func isHeadingClass(_ t: ProbeTree, _ i: Int) -> Bool {
        let n = t.nodes[i]
        guard n.classes.contains(where: { c in let l = c.lowercased(); return l.contains("heading") && !l.contains("subheading") }),
              t.textBelow[i] > 0, t.textBelow[i] <= 300 else { return false }
        return !t.inOrder(from: i).contains { ["AXList", "AXTable", "AXRow"].contains(t.nodes[$0].role) || controlRoles.contains(t.nodes[$0].role) }
    }

    /// The level from the heading itself, from a heading inside it, or from an `h1`…`h6` class;
    /// else 3, a section heading inside a reply.
    static func headingLevel(_ t: ProbeTree, _ i: Int) -> Int {
        if let l = t.inOrder(from: i).compactMap({ t.nodes[$0].role == "AXHeading" ? t.nodes[$0].level : nil }).first { return min(6, max(1, l)) }
        for c in t.nodes[i].classes {
            let l = c.lowercased()
            if l.count == 2, l.first == "h", let d = l.last?.wholeNumberValue, (1...6).contains(d) { return d }
        }
        return 3
    }

    /// A list's items, nested lists one level deeper. Every child of a list is an item (Chromium
    /// reports list items as plain groups).
    static func list(_ t: ProbeTree, _ i: Int, depth: Int, into out: inout [Block]) {
        let orderedList = t.nodes[i].classes.contains { c in
            let l = c.lowercased()
            return l.contains("orderedlist") && !l.contains("unorderedlist")
        }
        for item in t.children[i] {
            var parts: [Int] = [], nested: [Int] = [], code: [Int] = []
            var ordered = orderedList
            for k in t.children[item].isEmpty ? [item] : t.children[item] {
                switch t.nodes[k].role {
                case "AXList": nested.append(k)
                case "AXListMarker":
                    let mark = (text(t.nodes[k]) ?? joined(inlines(t, k, insideControl: true))).trimmingWhitespace
                    if let c = mark.first { ordered = c.isNumber }
                default:
                    if isCodeBlock(t, k) { code.append(k) } else { parts.append(k) }
                }
            }
            let s = trimmed(separated(t, parts))
            if !s.isEmpty { out.append(.listItem(level: depth, ordered: ordered, s)) }
            for c in code { let text = codeText(t, c); if !text.trimmingWhitespace.isEmpty { out.append(.code(text, language: codeLanguage(t, c))) } }
            for n in nested { list(t, n, depth: depth + 1, into: &out) }
        }
    }

    /// A table's rows of cell text, the first row being the header; nil if `i` isn't a table.
    static func table(_ t: ProbeTree, _ i: Int) -> [[String]]? {
        guard t.nodes[i].role == "AXTable" else { return nil }
        let rows = t.inOrder(from: i).filter { t.nodes[$0].role == "AXRow" }
        guard !rows.isEmpty else { return nil }
        return rows.compactMap { r in
            let cells = t.children[r].map { c in
                joined(separated(t, t.children[c].isEmpty ? [c] : t.children[c])).replacingAll("\n", with: " ").trimmingWhitespace
            }
            return cells.allSatisfy(\.isEmpty) ? nil : cells
        }
    }

    /// The text of an element and everything inside it, as runs (links keep their address). Two
    /// pieces that are separate elements (not text, a link or inline code) get a space between
    /// them when neither has one, so "Sales Report" and "Export" don't run together.
    static func inlines(_ t: ProbeTree, _ i: Int, insideControl: Bool = false) -> [Inline] {
        let n = t.nodes[i]
        if !insideControl, controlRoles.contains(n.role) || n.role == "AXListMarker" { return [] }
        if skipRoles.contains(n.role) || n.subrole.map(skipSubroles.contains) == true { return [] }
        if n.role == "AXStaticText" { return (text(n) ?? "").isEmpty ? [] : [Inline(text(n)!)] }
        var inner: [Inline] = [], lastSeparate = false
        for k in t.children[i] {
            let spans = inlines(t, k, insideControl: insideControl)
            guard let first = spans.first?.text.first else { continue }
            let separate = t.nodes[k].role == "AXGroup" && !isCodeStyle(t.nodes[k])
            if separate || lastSeparate, let last = inner.last?.text.last,
               !last.isWhitespace, !first.isWhitespace, !".,;:!?)]}".contains(first) {
                inner.append(Inline(" "))
            }
            inner += spans
            lastSeparate = separate
        }
        if n.role == "AXLink" {
            let label = joined(inner).isEmpty ? (n.label.map(HTMLEntities.decode) ?? "") : joined(inner)
            return label.isEmpty ? [] : [Inline(label, link: n.url.map(HTMLEntities.decode))]
        }
        return merged(inner)
    }

    /// Neighbouring plain runs as one (keeps runs with links apart).
    static func merged(_ spans: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for s in spans {
            if let last = out.last, last.link == nil, s.link == nil { out[out.count - 1].text += s.text } else { out.append(s) }
        }
        return out
    }

    static func joined(_ spans: [Inline]) -> String { spans.map(\.text).joined() }

    /// The runs of several elements in a row: a line break between two that are blocks of their
    /// own (two paragraphs of one list item or table cell), a space where needed otherwise.
    static func separated(_ t: ProbeTree, _ elements: [Int]) -> [Inline] {
        var out: [Inline] = [], previousWasBlock = false
        for k in elements {
            let spans = inlines(t, k)
            guard !joined(spans).trimmingWhitespace.isEmpty else { continue }
            let isBlock = !inlineRoles.contains(t.nodes[k].role) && !isInlineLeaf(t, k) || isParagraph(t.nodes[k])
            if !out.isEmpty, isBlock || previousWasBlock { out.append(Inline("\n")) }
            else if let last = out.last?.text.last, let first = spans.first?.text.first, !last.isWhitespace, !first.isWhitespace,
                    t.nodes[k].role == "AXGroup", !isCodeStyle(t.nodes[k]) { out.append(Inline(" ")) }
            out += trimmed(spans)
            previousWasBlock = isBlock
        }
        return merged(out)
    }

    /// Without spaces and line breaks at the very start and end.
    static func trimmed(_ spans: [Inline]) -> [Inline] {
        var s = spans
        while let f = s.first, f.text.trimmingWhitespace.isEmpty { s.removeFirst() }
        while let l = s.last, l.text.trimmingWhitespace.isEmpty { s.removeLast() }
        guard !s.isEmpty else { return [] }
        s[0].text = String(s[0].text.drop(while: \.isWhitespace))
        var last = Substring(s[s.count - 1].text)
        while let c = last.last, c.isWhitespace { last = last.dropLast() }
        s[s.count - 1].text = String(last)
        return s
    }

    /// One paragraph: text and links only, or inline pieces (bold, inline code) mixed with text.
    /// A group of separate paragraphs (several groups and no text of its own) is not one.
    static func isInlineRun(_ t: ProbeTree, _ i: Int) -> Bool {
        if inlineRoles.contains(t.nodes[i].role) { return true }
        let kids = t.children[i]
        guard !kids.isEmpty, kids.allSatisfy({ isInlineLeaf(t, $0) }) else { return false }
        return kids.count == 1 || kids.contains { inlineRoles.contains(t.nodes[$0].role) }
    }

    static func isInlineLeaf(_ t: ProbeTree, _ c: Int) -> Bool {
        let n = t.nodes[c]
        if inlineRoles.contains(n.role) || n.role == "AXListMarker" { return true }
        if controlRoles.contains(n.role) || skipRoles.contains(n.role) || n.subrole.map(skipSubroles.contains) == true { return false }
        if ["AXHeading", "AXList", "AXTable", "AXRow", "AXCell"].contains(n.role) || isParagraph(n) || isHeadingClass(t, c) || isCodeBlock(t, c) {
            return false
        }
        let kids = t.children[c]
        if kids.isEmpty { return t.textBelow[c] == 0 }
        return kids.allSatisfy { inlineRoles.contains(t.nodes[$0].role) }
    }

    static func isParagraph(_ n: ProbeNode) -> Bool {
        n.classes.contains { $0.lowercased().contains("paragraph") } || n.roleDescription?.lowercased() == "paragraph"
    }

    // MARK: Code

    /// Classes of a code block: `_CodeBlock_…`, `language-…`, and ChatGPT's code panel
    /// (`_CodeSurface_…`, the code of an "Analyzed" Python block).
    static func hasCodeBlockClass(_ n: ProbeNode) -> Bool {
        n.classes.contains { c in
            let l = c.lowercased()
            return l.contains("codeblock") || l.contains("code-block") || l.contains("codesurface") || l.hasPrefix("language-")
        }
    }

    static func isCodeStyle(_ n: ProbeNode) -> Bool {
        n.subrole == "AXCodeStyleGroup" || n.roleDescription?.lowercased() == "code"
    }

    /// The element with the code block's class: `i` or one a few levels inside it.
    static func codeHolder(_ t: ProbeTree, _ i: Int) -> Int? {
        var level = [i]
        for _ in 0..<4 {
            if let hit = level.first(where: { hasCodeBlockClass(t.nodes[$0]) }) { return hit }
            level = level.flatMap { t.children[$0] }
            if level.isEmpty { break }
        }
        return nil
    }

    /// A code block: an element with a code block's class, or a frame around one that holds only
    /// short labels besides the code ("Analyzed", "Python", a Copy button), or code whose text has
    /// more than one line. Single-line code inside a paragraph stays part of the paragraph.
    static func isCodeBlock(_ t: ProbeTree, _ i: Int) -> Bool {
        if hasCodeBlockClass(t.nodes[i]) { return true }
        if let h = codeHolder(t, i), t.textBelow[i] - t.textBelow[h] <= 40,
           !["AXScrollArea", "AXWebArea", "AXList", "AXTable"].contains(t.nodes[i].role) {
            // Only labels and buttons besides the code: nothing that is content of its own.
            let code = Set(t.inOrder(from: h))
            let content = t.inOrder(from: i).contains { k in
                !code.contains(k) && (["AXList", "AXHeading", "AXTable"].contains(t.nodes[k].role) || isParagraph(t.nodes[k]))
            }
            if !content { return true }
        }
        return isCodeStyle(t.nodes[i]) && codeText(t, i).contains("\n")
    }

    /// The code itself: inside a code block's frame, the code element (so labels and buttons
    /// aren't taken as code). Lines drawn as one element each (a code editor) get line breaks.
    static func codeText(_ t: ProbeTree, _ i: Int) -> String {
        let holder = codeHolder(t, i) ?? i
        let root = t.inOrder(from: holder).first { isCodeStyle(t.nodes[$0]) && t.textBelow[$0] > 0 } ?? holder
        func staticTexts(_ r: Int) -> String {
            t.inOrder(from: r).compactMap { k -> String? in
                let n = t.nodes[k]
                guard n.role == "AXStaticText", !insideControl(t, k, below: r) else { return nil }
                return text(n)
            }.joined()
        }
        var code = staticTexts(root)
        if !code.contains("\n") {
            // One element per line: the element inside with the most children that hold text.
            var best: (Int, [Int])?
            for k in t.inOrder(from: root) {
                let lines = t.children[k].filter { t.textBelow[$0] > 0 && !controlRoles.contains(t.nodes[$0].role) }
                if lines.count >= 2, lines.count > (best?.1.count ?? 0) { best = (k, lines) }
            }
            if let (_, lines) = best, lines.allSatisfy({ t.nodes[$0].role != "AXStaticText" }) {
                code = lines.map(staticTexts).joined(separator: "\n")
            }
        }
        while code.last == "\n" { code.removeLast() }
        return code
    }

    static func insideControl(_ t: ProbeTree, _ k: Int, below root: Int) -> Bool {
        var p = t.nodes[k].parent
        while let q = p, q != root {
            if controlRoles.contains(t.nodes[q].role) { return true }
            p = t.nodes[q].parent
        }
        return false
    }

    /// Languages a code block's label can name, for the Markdown fence.
    static let languages: [String: String] = [
        "python": "python", "javascript": "javascript", "js": "javascript", "typescript": "typescript", "ts": "typescript",
        "swift": "swift", "bash": "bash", "shell": "bash", "sh": "sh", "zsh": "zsh", "json": "json", "html": "html", "css": "css",
        "sql": "sql", "ruby": "ruby", "go": "go", "rust": "rust", "java": "java", "kotlin": "kotlin", "c": "c", "c++": "cpp",
        "cpp": "cpp", "c#": "csharp", "csharp": "csharp", "php": "php", "r": "r", "yaml": "yaml", "yml": "yaml", "xml": "xml",
        "markdown": "markdown", "diff": "diff", "powershell": "powershell", "scala": "scala", "perl": "perl", "lua": "lua",
        "dart": "dart", "toml": "toml", "dockerfile": "dockerfile", "makefile": "makefile", "plaintext": "text", "text": "text",
        "objective-c": "objectivec", "jsx": "jsx", "tsx": "tsx", "graphql": "graphql", "latex": "latex", "matlab": "matlab",
    ]

    /// The language a code block names: a `language-…` class, else a short label beside the code.
    static func codeLanguage(_ t: ProbeTree, _ i: Int) -> String? {
        for k in t.inOrder(from: i) {
            for c in t.nodes[k].classes where c.lowercased().hasPrefix("language-") {
                let name = String(c.dropFirst("language-".count)).lowercased()
                return languages[name] ?? name
            }
        }
        let holder = codeHolder(t, i) ?? i
        let code = Set(t.inOrder(from: t.inOrder(from: holder).first { isCodeStyle(t.nodes[$0]) && t.textBelow[$0] > 0 } ?? holder))
        for k in t.inOrder(from: i) where t.nodes[k].role == "AXStaticText" && !code.contains(k) {
            if let name = text(t.nodes[k])?.trimmingWhitespace.lowercased(), let l = languages[name] { return l }
        }
        return nil
    }

    // MARK: Repeats

    /// A block repeated right after itself (an app that gives the same text twice, once for screen
    /// readers) is kept once, and a paragraph that is one sentence twice in a row loses the copy.
    static func withoutRepeats(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for p in pieces {
            guard case .block(var b, let u, let f) = p else { out.append(p); continue }
            if case .paragraph(let spans) = b, spans.count == 1, spans[0].link == nil, let half = doubled(spans[0].text) {
                b = .paragraph([Inline(half)])
            }
            if case .block(let previous, _, _)? = out.last, previous == b { continue }
            out.append(.block(b, user: u, frame: f))
        }
        return out
    }

    /// "Same sentence. Same sentence." → "Same sentence." (only text of 20 characters or more,
    /// repeated exactly, with or without a space between).
    static func doubled(_ s: String) -> String? {
        let t = s.trimmingWhitespace
        guard t.count >= 40 else { return nil }
        for gap in [0, 1] where (t.count - gap) % 2 == 0 {
            let half = (t.count - gap) / 2
            let a = String(t.prefix(half)), b = String(t.suffix(half))
            if a == b, half >= 20 { return a }
        }
        return nil
    }

    // MARK: Who said what

    static func speakers(_ pieces: [Piece]) -> ChatReading {
        var blocks: [Block] = [], users: [Bool] = [], frames: [CGRect?] = []
        for p in pieces { if case .block(let b, let u, let f) = p { blocks.append(b); users.append(u); frames.append(f) } }
        // Marks on only some of the user's messages would put the others under the reply: when
        // the buttons find more of the user's turns, they win.
        let byClass: [Speaker] = users.map { $0 ? .user : .assistant }
        let byButton = byButtons(pieces)
        func userTurns(_ l: [Speaker]?) -> Int { group(blocks, l ?? []).filter { $0.speaker == .user }.count }
        let classesFirst = userTurns(byClass) >= userTurns(byButton)
        let rules: [(SpeakerRule, [Speaker]?)] = [(.labels, byLabels(pieces))] + (classesFirst
            ? [(.classes, byClass), (.buttons, byButton), (.layout, byLayout(frames))]
            : [(.buttons, byButton), (.classes, byClass), (.layout, byLayout(frames))])
        for (rule, labels) in rules {
            guard let labels, labels.contains(.user), labels.contains(.assistant) else { continue }
            return ChatReading(turns: group(blocks, labels), rule: rule)
        }
        return ChatReading(turns: blocks.isEmpty ? [] : [ChatTurn(speaker: nil, blocks: blocks)], rule: .none)
    }

    /// Each block is said by whoever the last "… said:" label before it names. Blocks before the
    /// first label are labelled as not-yours, so `group` gives them no speaker.
    static func byLabels(_ pieces: [Piece]) -> [Speaker]? {
        var labels: [Speaker] = [], current: Speaker = .assistant, any = false
        for p in pieces {
            switch p {
            case .mark(let s): current = s; any = true
            case .block: labels.append(current)
            case .control: break
            }
        }
        return any ? labels : nil
    }

    /// Turns from labelled blocks: a new turn whenever the speaker changes. Blocks before the
    /// user's first message (a chat title, a notice) get no speaker.
    static func group(_ blocks: [Block], _ labels: [Speaker]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var seenUser = false
        for (b, l) in zip(blocks, labels) {
            if l == .user { seenUser = true }
            let speaker: Speaker? = seenUser ? l : nil
            if let last = turns.last, last.speaker == speaker { turns[turns.count - 1].blocks.append(b) }
            else { turns.append(ChatTurn(speaker: speaker, blocks: [b])) }
        }
        return turns
    }

    /// Blocks up to a "Copy message" or "Edit message" button are the user's; up to a reply's
    /// button ("Good response"...), a reply. Each closes at once, in order, so a reply followed
    /// directly by a message with no text (only a picture) stays a reply. Other buttons (Copy
    /// code, Show more) end nothing, unless the app has no reply buttons at all, when any group
    /// of buttons ends a reply. Before the user's first message, only the blocks after the last
    /// button count as that message: a chat title with its own buttons above it gets no speaker.
    static func byButtons(_ pieces: [Piece]) -> [Speaker]? {
        let all = pieces.compactMap { p -> String? in if case .control(let l) = p { return normalized(l) } else { return nil } }
        guard all.contains(where: userButtonLabels.contains) else { return nil }
        let replyButtons = all.contains(where: replyButtonLabels.contains)
        var labels: [Speaker] = [], pending = 0, sinceButton = 0, inGroup = false, seenUser = false, boundary = false
        func close(_ s: Speaker) {
            if s == .user && !seenUser {
                // The preamble: labelled as not-yours, so `group` gives it no speaker.
                labels += Array(repeating: .assistant, count: pending - sinceButton)
                labels += Array(repeating: .user, count: sinceButton)
                seenUser = true
            } else {
                labels += Array(repeating: s, count: pending)
            }
            pending = 0; sinceButton = 0
        }
        for p in pieces {
            switch p {
            case .control(let l):
                let n = normalized(l)
                if userButtonLabels.contains(n) { close(.user) } else if replyButtonLabels.contains(n) { close(.assistant) }
                inGroup = true
                if !inMessageButtonLabels.contains(n) { boundary = true }
            case .block:
                if inGroup {
                    inGroup = false
                    if boundary {
                        if !replyButtons { close(.assistant) }
                        sinceButton = 0
                    }
                    boundary = false
                }
                pending += 1; sinceButton += 1
            case .mark: break
            }
        }
        labels += Array(repeating: .assistant, count: pending)
        return labels
    }

    /// The user's messages sit on the right in narrower bubbles: a block that starts well right
    /// of the column's left edge, ends near its right edge and is under four fifths of its width.
    /// Only when most blocks have real frames (some apps report every element at the same place).
    static func byLayout(_ frames: [CGRect?]) -> [Speaker]? {
        let real = frames.compactMap { $0 }.filter { $0.width >= 20 && $0.height >= 1 }
        guard !frames.isEmpty, Double(real.count) >= Double(frames.count) * 0.8,
              let left = real.map(\.minX).min(), let right = real.map(\.maxX).max(), right - left >= 100 else { return nil }
        let width = right - left
        return frames.map { f in
            guard let f, f.width >= 20 else { return .assistant }
            let user = f.minX - left > width * 0.2 && right - f.maxX < width * 0.12 && f.width < width * 0.8
            return user ? .user : .assistant
        }
    }
}

/// Character references left in an app's text ("&amp;", "&#39;", "&#x2F;"), decoded once.
public enum HTMLEntities {
    static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                          "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
                                          "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "middot": "·"]

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(33).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var value: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let n = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) {
                    value = String(Character(u))
                } else if name.hasPrefix("#"), let n = UInt32(name.dropFirst()), let u = Unicode.Scalar(n) {
                    value = String(Character(u))
                } else {
                    value = named[name]
                }
                if let value {
                    out += value
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }
}

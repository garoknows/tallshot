import CoreGraphics

/// Who said something in a chat.
public enum Speaker: String, Sendable, Equatable {
    case user, assistant
}

/// How Tallshot told the user's messages from the replies.
public enum SpeakerRule: String, Sendable, Equatable {
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

/// A whole conversation read from an app's accessibility tree.
public struct ChatReading: Equatable, Sendable {
    public var turns: [ChatTurn]
    public var rule: SpeakerRule

    public var userTurns: Int { turns.filter { $0.speaker == .user }.count }
    public var replyTurns: Int { turns.filter { $0.speaker == .assistant }.count }
    public var hasText: Bool { turns.contains { $0.blocks.contains { !$0.plainText.trimmingWhitespace.isEmpty } } }
}

/// Reads a chat app's whole conversation from its accessibility tree (every message, including
/// those scrolled out of view: only used for apps whose tree holds the whole conversation), with
/// headings, paragraphs, lists, links and code blocks, and who said each part. Pure: the app's
/// `TreeWalker` collects the tree, this turns it into turns.
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
    static let inlineRoles: Set<String> = ["AXStaticText", "AXLink"]

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
        return speakers(pieces)
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

    // MARK: The tree, in order: blocks of content and the buttons between them

    enum Piece: Equatable {
        case block(Block, user: Bool, frame: CGRect?)
        case control(String)
    }

    static func walk(_ t: ProbeTree, _ i: Int, user inherited: Bool, into out: inout [Piece]) {
        let n = t.nodes[i]
        let user = inherited || n.classes.contains(where: isUserClass)
        if controlRoles.contains(n.role) {
            let label = n.label.map(\.trimmingWhitespace).flatMap { $0.isEmpty ? nil : $0 } ?? joined(inlines(t, i, insideControl: true))
            out.append(.control(label))
            return
        }
        if skipRoles.contains(n.role) { return }
        func emit(_ b: Block) { out.append(.block(b, user: user, frame: n.frame)) }
        switch n.role {
        case "AXHeading":
            let text = joined(inlines(t, i)).trimmingWhitespace
            if !text.isEmpty { emit(.heading(level: min(6, max(1, n.level ?? 2)), [Inline(text)])) }
        case "AXList":
            var items: [Block] = []
            list(t, i, depth: 0, into: &items)
            items.forEach(emit)
        default:
            // A table: one line per row, cells separated by " | ".
            let rows = n.role == "AXTable" ? t.inOrder(from: i).filter { t.nodes[$0].role == "AXRow" } : []
            if !rows.isEmpty {
                for r in rows {
                    let cells = t.children[r].map { joined(separated(t, t.children[$0].isEmpty ? [$0] : t.children[$0])).replacingAll("\n", with: " ").trimmingWhitespace }
                        .filter { !$0.isEmpty }
                    if !cells.isEmpty { emit(.paragraph([Inline(cells.joined(separator: " | "))])) }
                }
                return
            }
            if isCodeBlock(t, i) {
                let code = codeText(t, i)
                if !code.trimmingWhitespace.isEmpty { emit(.code(code)) }
                return
            }
            if isInlineRun(t, i) {
                let spans = trimmed(inlines(t, i))
                if !spans.isEmpty { emit(.paragraph(spans)) }
                return
            }
            for k in t.children[i] { walk(t, k, user: user, into: &out) }
        }
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
                    let mark = (t.nodes[k].text ?? joined(inlines(t, k, insideControl: true))).trimmingWhitespace
                    if let c = mark.first { ordered = c.isNumber }
                default:
                    if isCodeBlock(t, k) { code.append(k) } else { parts.append(k) }
                }
            }
            let s = trimmed(separated(t, parts))
            if !s.isEmpty { out.append(.listItem(level: depth, ordered: ordered, s)) }
            for c in code { let text = codeText(t, c); if !text.trimmingWhitespace.isEmpty { out.append(.code(text)) } }
            for n in nested { list(t, n, depth: depth + 1, into: &out) }
        }
    }

    /// The text of an element and everything inside it, as runs (links keep their address).
    static func inlines(_ t: ProbeTree, _ i: Int, insideControl: Bool = false) -> [Inline] {
        let n = t.nodes[i]
        if !insideControl, controlRoles.contains(n.role) || n.role == "AXListMarker" { return [] }
        if skipRoles.contains(n.role) { return [] }
        if n.role == "AXStaticText" { return (n.text ?? "").isEmpty ? [] : [Inline(n.text!)] }
        let inner = t.children[i].flatMap { inlines(t, $0, insideControl: insideControl) }
        if n.role == "AXLink" {
            let text = joined(inner).isEmpty ? (n.label ?? "") : joined(inner)
            return text.isEmpty ? [] : [Inline(text, link: n.url)]
        }
        return inner
    }

    static func joined(_ spans: [Inline]) -> String { spans.map(\.text).joined() }

    /// The runs of several elements in a row: a line break between two that are blocks of their
    /// own (two paragraphs of one list item or table cell), nothing between inline pieces.
    static func separated(_ t: ProbeTree, _ elements: [Int]) -> [Inline] {
        var out: [Inline] = [], previousWasBlock = false
        for k in elements {
            let spans = inlines(t, k)
            guard !joined(spans).trimmingWhitespace.isEmpty else { continue }
            let isBlock = !inlineRoles.contains(t.nodes[k].role) && !isInlineLeaf(t, k) || isParagraph(t.nodes[k])
            if !out.isEmpty, isBlock || previousWasBlock { out.append(Inline("\n")) }
            out += trimmed(spans)
            previousWasBlock = isBlock
        }
        return out
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
        if controlRoles.contains(n.role) || skipRoles.contains(n.role) { return false }
        if ["AXHeading", "AXList", "AXTable", "AXRow", "AXCell"].contains(n.role) || isParagraph(n) || isCodeBlock(t, c) { return false }
        let kids = t.children[c]
        if kids.isEmpty { return t.textBelow[c] == 0 }
        return kids.allSatisfy { inlineRoles.contains(t.nodes[$0].role) }
    }

    static func isParagraph(_ n: ProbeNode) -> Bool {
        n.classes.contains { $0.lowercased().contains("paragraph") } || n.roleDescription?.lowercased() == "paragraph"
    }

    static func hasCodeBlockClass(_ n: ProbeNode) -> Bool {
        n.classes.contains { c in
            let l = c.lowercased()
            return l.contains("codeblock") || l.contains("code-block") || l.hasPrefix("language-")
        }
    }

    static func isCodeStyle(_ n: ProbeNode) -> Bool {
        n.subrole == "AXCodeStyleGroup" || n.roleDescription?.lowercased() == "code"
    }

    /// A code block: marked as one by its class, or code whose text has more than one line.
    /// Single-line code inside a paragraph stays part of the paragraph.
    static func isCodeBlock(_ t: ProbeTree, _ i: Int) -> Bool {
        let n = t.nodes[i]
        if hasCodeBlockClass(n) { return true }
        return isCodeStyle(n) && codeText(t, i).contains("\n")
    }

    /// A code block's text exactly. Inside a code block's frame (with a language label and a Copy
    /// button), the code element itself is used, so the label isn't taken as code.
    static func codeText(_ t: ProbeTree, _ i: Int) -> String {
        let inner = t.inOrder(from: i).dropFirst().first { isCodeStyle(t.nodes[$0]) && t.textBelow[$0] > 0 }
        let root = hasCodeBlockClass(t.nodes[i]) ? (inner ?? i) : i
        var text = t.inOrder(from: root).compactMap { t.nodes[$0].role == "AXStaticText" ? t.nodes[$0].text : nil }.joined()
        while text.last == "\n" { text.removeLast() }
        return text
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
        let rules: [(SpeakerRule, [Speaker]?)] = classesFirst
            ? [(.classes, byClass), (.buttons, byButton), (.layout, byLayout(frames))]
            : [(.buttons, byButton), (.classes, byClass), (.layout, byLayout(frames))]
        for (rule, labels) in rules {
            guard let labels, labels.contains(.user), labels.contains(.assistant) else { continue }
            return ChatReading(turns: group(blocks, labels), rule: rule)
        }
        return ChatReading(turns: blocks.isEmpty ? [] : [ChatTurn(speaker: nil, blocks: blocks)], rule: .none)
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

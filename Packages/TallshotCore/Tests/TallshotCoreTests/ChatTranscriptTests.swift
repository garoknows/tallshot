import CoreGraphics
import Testing
@testable import TallshotCore

/// A pretend accessibility tree, built in document order. The shapes follow the ChatGPT app's own
/// page code (read from its app bundle on 2026-11-10): your message is `group/user-message` >
/// bubble > `rich-text-user-turn` Markdown > paragraphs, followed by "Copy message" and "Edit
/// message" buttons; a reply is Markdown (`_Paragraph_`, `_Heading_`, `_List_`, `_CodeBlock_`)
/// followed by "Copy", "Good response" and "Bad response". Chromium may leave the wrapper boxes
/// out of the tree, which makes the conversation one flat list (what probe 2 saw: 117 children,
/// 79 with `_Paragraph_`).
private struct Tree {
    var nodes: [ProbeNode] = []

    @discardableResult
    mutating func add(_ role: String, _ parent: Int?, text: String? = nil, label: String? = nil, url: String? = nil,
                      level: Int? = nil, classes: [String] = [], subrole: String? = nil, frame: CGRect? = nil) -> Int {
        nodes.append(ProbeNode(role: role, frame: frame, classes: classes, parent: parent, text: text, label: label,
                               url: url, level: level, subrole: subrole))
        return nodes.count - 1
    }

    @discardableResult
    mutating func p(_ parent: Int, _ text: String, classes: [String] = ["_Paragraph_xjxw3_2"], frame: CGRect? = nil) -> Int {
        let g = add("AXGroup", parent, classes: classes, frame: frame)
        add("AXStaticText", g, text: text, frame: frame)
        return g
    }

    mutating func buttons(_ parent: Int, _ labels: String...) { for l in labels { add("AXButton", parent, label: l) } }

    /// A window with a narrow sidebar of chat titles and the conversation's scroll area.
    mutating func window(sidebarTitles: Int = 0) -> (window: Int, area: Int) {
        let w = add("AXWindow", nil, frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let side = add("AXScrollArea", w, frame: CGRect(x: 0, y: 40, width: 260, height: 860))
        for i in 0..<sidebarTitles { add("AXStaticText", side, text: "A chat about topic number \(i)") }
        let area = add("AXScrollArea", w, frame: CGRect(x: 260, y: 40, width: 940, height: 760))
        add("AXTextArea", w, frame: CGRect(x: 300, y: 820, width: 800, height: 60))   // the message box
        return (w, area)
    }

    var tree: ProbeTree { ProbeTree(nodes) }
}

/// The flat shape: every block and button a child of one element.
private func flatChat() -> (Tree, area: Int) {
    var t = Tree()
    let (_, area) = t.window()
    let list = t.add("AXGroup", area)
    t.p(list, "Plan a trip to Lisbon for me")
    t.buttons(list, "Copy message", "Edit message")
    t.add("AXHeading", list, level: 2, classes: ["_Heading_xjxw3_2"])
    t.add("AXStaticText", t.nodes.count - 1, text: "Day one")
    let para = t.add("AXGroup", list, classes: ["_Paragraph_xjxw3_2"])
    t.add("AXStaticText", para, text: "Start at ")
    let link = t.add("AXLink", para, url: "https://example.org/belem")
    t.add("AXStaticText", link, text: "Belém Tower")
    t.add("AXStaticText", para, text: ", then lunch.")
    let ul = t.add("AXList", list, classes: ["_List_xjxw3_2", "_UnorderedList_xjxw3_2"])
    let li1 = t.add("AXGroup", ul, classes: ["_ListItem_xjxw3_2"])
    t.add("AXStaticText", li1, text: "Pastéis de nata")
    let nested = t.add("AXList", li1, classes: ["_List_xjxw3_2"])
    let li11 = t.add("AXGroup", nested, classes: ["_ListItem_xjxw3_2"])
    t.add("AXStaticText", li11, text: "at the corner bakery")
    let li2 = t.add("AXGroup", ul, classes: ["_ListItem_xjxw3_2"])
    t.add("AXStaticText", li2, text: "Tram 28")
    let block = t.add("AXGroup", list, classes: ["_CodeBlock_xjxw3_2"])
    t.add("AXStaticText", block, text: "python")
    t.buttons(block, "Copy")
    let code = t.add("AXGroup", block, subrole: "AXCodeStyleGroup")
    t.add("AXStaticText", code, text: "days = 3\n")
    t.add("AXStaticText", code, text: "print(days)\n")
    t.buttons(list, "Copy", "Good response", "Bad response", "More actions")
    t.p(list, "Make it two days\nand cheaper")
    t.buttons(list, "Copy message", "Edit message")
    let reply = t.add("AXGroup", list, classes: ["_Paragraph_xjxw3_2"])
    t.add("AXStaticText", reply, text: "Run ")
    let inline = t.add("AXGroup", reply, classes: ["_InlineCode_xjxw3_2"], subrole: "AXCodeStyleGroup")
    t.add("AXStaticText", inline, text: "budget --days 2")
    t.add("AXStaticText", reply, text: " first.")
    t.buttons(list, "Copy", "Good response", "Bad response")
    return (t, area)
}

@Suite("Chat apps: the whole conversation as text, with who said what")
struct ChatTranscriptTests {
    @Test func theFlatChatGPTShapeIsSplitByItsButtons() throws {
        let (t, area) = flatChat()
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.rule == .buttons)
        try #require(r.turns.map(\.speaker) == [.user, .assistant, .user, .assistant])
        #expect(r.turns[0].blocks == [.paragraph([Inline("Plan a trip to Lisbon for me")])])
        #expect(r.turns[2].blocks == [.paragraph([Inline("Make it two days\nand cheaper")])])
        #expect(r.userTurns == 2 && r.replyTurns == 2)
    }

    @Test func headingsListsLinksAndCodeAreKept() {
        let (t, area) = flatChat()
        let doc = ChatTranscript.document(ChatTranscript.read(tree: t.tree, area: area), assistantName: "ChatGPT")
        let md = Markdown.render(doc)
        #expect(md.contains("**You:**\n\nPlan a trip to Lisbon for me"))
        #expect(md.contains("**ChatGPT:**\n\n## Day one"))
        #expect(md.contains("Start at [Belém Tower](https://example.org/belem), then lunch."))
        #expect(md.contains("- Pastéis de nata\n  - at the corner bakery\n- Tram 28"))
        #expect(md.contains("```\ndays = 3\nprint(days)\n```"), "the code exactly, without the language label")
        #expect(!md.contains("python"))
        #expect(md.contains("Make it two days  \nand cheaper"), "your line breaks stay")
        #expect(md.contains("Run budget --days 2 first."), "inline code stays in its paragraph")
        #expect(!md.contains("Good response") && !md.contains("Copy message"), "buttons aren't text")
    }

    @Test func wrapperClassesWinWhenTheTreeHasThem() throws {
        var t = Tree()
        let (_, area) = t.window()
        let turns = t.add("AXGroup", area)
        for i in 0..<3 {
            let mine = t.add("AXGroup", turns, classes: ["group/user-message", "flex", "w-full", "items-end"])
            let bubble = t.add("AXGroup", mine, classes: ["relative", "w-full"])
            let md = t.add("AXGroup", bubble, classes: ["text-size-chat", "rich-text-user-turn", "_MarkdownRoot_xjxw3_2"])
            t.p(md, "Question \(i)")
            let answer = t.add("AXGroup", turns, classes: ["_MarkdownRoot_xjxw3_2"])
            t.p(answer, "Answer \(i), first part")
            t.p(answer, "Answer \(i), second part")
        }
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.rule == .classes)
        try #require(r.turns.map(\.speaker) == [.user, .assistant, .user, .assistant, .user, .assistant])
        #expect(r.turns[1].blocks.count == 2, "a reply's paragraphs stay apart, in one turn")
    }

    @Test func otherButtonsInsideATurnDontSplitIt() {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        t.p(list, "A long question, first part")
        t.buttons(list, "Show more")
        t.p(list, "second part")
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "Reply before code")
        t.buttons(list, "Copy code")
        t.p(list, "Reply after code")
        t.buttons(list, "Copy", "Good response", "Bad response")
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.turns.map(\.speaker) == [.user, .assistant])
        #expect(r.turns.map(\.blocks.count) == [2, 2])
    }

    @Test func showMoreDoesntSplitYourMessageEvenWithoutReplyButtons() throws {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        t.p(list, "Answer before")
        t.buttons(list, "Copy")
        t.p(list, "My long question, part one")
        t.buttons(list, "Show more")
        t.p(list, "part two")
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "The answer")
        t.buttons(list, "Copy")
        let r = ChatTranscript.read(tree: t.tree, area: area)
        try #require(r.turns.map(\.speaker) == [nil, .user, .assistant])
        #expect(r.turns[1].blocks.count == 2)
    }

    @Test func withoutMarksTheLayoutTells() {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        let wide = CGRect(x: 300, y: 100, width: 760, height: 40), bubble = CGRect(x: 640, y: 100, width: 420, height: 40)
        t.p(list, "my question", frame: bubble)
        t.p(list, "the answer", frame: wide)
        t.p(list, "more answer", frame: wide)
        t.p(list, "my follow-up", frame: bubble)
        t.p(list, "second answer", frame: wide)
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.rule == .layout)
        #expect(r.turns.map(\.speaker) == [.user, .assistant, .user, .assistant])
    }

    @Test func withNothingToTellThereAreNoLabels() throws {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        let same = CGRect(x: 300, y: 0, width: 760, height: 0)   // every element reported at one place
        for i in 0..<4 { t.p(list, "Message \(i)", frame: same) }
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.rule == .none)
        try #require(r.turns.count == 1)
        #expect(r.turns[0].speaker == nil && r.turns[0].blocks.count == 4)
        let md = Markdown.render(ChatTranscript.document(r, assistantName: "Chat"))
        #expect(!md.contains("**You:**") && md.contains("Message 3"))
    }

    @Test func aClassOnEveryBlockIsNotASpeaker() {
        var t = Tree()
        let (_, area) = t.window()
        let all = t.add("AXGroup", area, classes: ["thread-user-message-container"])
        t.p(all, "one"); t.p(all, "two")
        #expect(ChatTranscript.read(tree: t.tree, area: area).rule == .none, "everything marked as yours means no mark at all")
    }

    @Test func blocksBeforeYourFirstMessageHaveNoSpeaker() {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        t.p(list, "Lisbon trip planning")
        t.buttons(list, "Rename chat")   // not a reply's button
        t.p(list, "Plan a trip")
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "Sure.")
        t.buttons(list, "Good response")
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.turns.map(\.speaker) == [nil, .user, .assistant])
    }

    @Test func separateParagraphsStaySeparate() {
        var t = Tree()
        let (_, area) = t.window()
        let div = t.add("AXGroup", area)
        t.p(div, "First paragraph.", classes: [])
        t.p(div, "Second paragraph.", classes: [])
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.turns.flatMap(\.blocks) == [.paragraph([Inline("First paragraph.")]), .paragraph([Inline("Second paragraph.")])])
    }

    @Test func aTableIsOneLinePerRow() {
        var t = Tree()
        let (_, area) = t.window()
        let table = t.add("AXTable", area)
        for row in [["City", "Days"], ["Lisbon", "2"]] {
            let r = t.add("AXRow", table)
            for c in row { let cell = t.add("AXCell", r); t.add("AXStaticText", cell, text: c) }
        }
        let col = t.add("AXColumn", table)
        t.add("AXStaticText", col, text: "City")   // columns repeat the cells: left out
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.turns.flatMap(\.blocks) == [.paragraph([Inline("City | Days")]), .paragraph([Inline("Lisbon | 2")])])
    }

    @Test func userMessageClassesAreRecognized() {
        for c in ["group/user-message", "rich-text-user-turn", "_userBubble_1pnp8_20", "human-turn", "text-user-message"] {
            #expect(ChatTranscript.isUserClass(c), "\(c)")
        }
        for c in ["thread-user-message-navigation-rail-7245db377d4d", "_Paragraph_xjxw3_2", "user-select-none", "assistant"] {
            #expect(!ChatTranscript.isUserClass(c), "\(c)")
        }
    }

    @Test func theConversationIsPickedOverABusySidebar() {
        var t = Tree()
        let (_, area) = t.window(sidebarTitles: 200)   // about 6,000 characters of chat titles
        let list = t.add("AXGroup", area)
        t.p(list, "A short chat about which bakery to visit first")
        t.p(list, "Start with the corner bakery near the tram stop: it opens at seven, the custard tarts come out warm, and the queue is short before eight. Then walk down to the river.")
        #expect(t.tree.messageArea() == area, "the wide area, not the narrow sidebar with more text")
        #expect(t.tree.messageArea(near: CGPoint(x: 700, y: 400)) == area, "the area under the pane's middle")
        #expect(t.tree.messageArea(near: CGPoint(x: 100, y: 400)) != area)
    }

    @Test func theReportCountsTurnButtonsAndHasNoChatText() {
        let (t, area) = flatChat()
        let tree = t.tree
        let reading = ChatTranscript.read(tree: tree, area: area)
        let r = ProbeReport.make(tree: tree, area: area, visible: CGRect(x: 260, y: 40, width: 940, height: 760), appName: "ChatGPT",
                                 bundleID: "com.openai.codex", settledAfter: 900, cutShort: false, reading: reading)
        #expect(r.userButtons == 4 && r.replyButtons == 5)
        #expect(r.text.contains("Speaker labels: from the Copy message and Edit message buttons under your messages; 2 of yours, 2 replies"))
        for secret in ["Lisbon", "Belém", "budget", "Tram", "Day one", "days = 3", "print", "two days", "cheaper", "python", "example.org"] {
            #expect(!r.text.contains(secret), "\(secret)")
        }
    }

    @Test func aReplyFollowedByAMessageWithNoTextStaysAReply() throws {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        t.p(list, "What's in this photo?")
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "A tram on a hill.")
        t.buttons(list, "Copy", "Good response", "Bad response")
        t.add("AXImage", list, label: "photo")              // your next message: only a picture
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "Another tram, at night.")
        t.buttons(list, "Copy", "Good response")
        let r = ChatTranscript.read(tree: t.tree, area: area)
        try #require(r.turns.map(\.speaker) == [.user, .assistant])
        #expect(r.turns[1].blocks.count == 2, "both replies, not the first under You")
    }

    @Test func classesOnOnlySomeOfYourMessagesLoseToTheButtons() throws {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        for i in 0..<3 {
            t.p(list, "Question \(i)", classes: i == 0 ? ["rich-text-user-turn"] : ["_Paragraph_xjxw3_2"])
            t.buttons(list, "Copy message", "Edit message")
            t.p(list, "Answer \(i)")
            t.buttons(list, "Copy", "Good response", "Bad response")
        }
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.rule == .buttons)
        #expect(r.userTurns == 3 && r.replyTurns == 3)
    }

    @Test func aListItemsParagraphsAndCodeStayApart() {
        var t = Tree()
        let (_, area) = t.window()
        let ul = t.add("AXList", area)
        let li = t.add("AXGroup", ul)
        t.p(li, "Pack light.")
        t.p(li, "Bring a jacket.")
        let block = t.add("AXGroup", li, classes: ["_CodeBlock_xjxw3_2"])
        t.add("AXStaticText", block, text: "bash")
        let code = t.add("AXGroup", block, subrole: "AXCodeStyleGroup")
        t.add("AXStaticText", code, text: "zip -r bag.zip clothes\n")
        let r = ChatTranscript.read(tree: t.tree, area: area)
        #expect(r.turns.flatMap(\.blocks) == [.listItem(level: 0, ordered: false, [Inline("Pack light."), Inline("\n"), Inline("Bring a jacket.")]),
                                               .code("zip -r bag.zip clothes")])
    }
}

@Suite("Chat apps: which ones copy the text")
struct ChatAppsTests {
    @Test func chatGPTCopiesTextAndClaudeScrollsUntilChecked() {
        #expect(ChatApps.usesText(bundleID: "com.openai.codex", checked: [:]))
        #expect(!ChatApps.usesText(bundleID: "com.anthropic.claudefordesktop", checked: [:]))
        #expect(!ChatApps.usesText(bundleID: "com.example.chat", checked: [:]))
        #expect(!ChatApps.usesText(bundleID: nil, checked: [:]))
    }

    @Test func aCheckedAnswerReplacesTheBuiltInOne() {
        let checked = ["com.openai.codex": CheckedApp(name: "ChatGPT", keepsWholeConversation: false, checked: "2026-11-10"),
                       "com.example.chat": CheckedApp(name: "Example", keepsWholeConversation: true, checked: "2026-11-10")]
        #expect(!ChatApps.usesText(bundleID: "com.openai.codex", checked: checked))
        #expect(ChatApps.usesText(bundleID: "com.example.chat", checked: checked))
        let rows = ChatApps.rows(checked: checked)
        #expect(rows.map(\.name) == ["ChatGPT", "Example", "Claude"])
        #expect(rows.map(\.source) == ["checked 2026-11-10", "checked 2026-11-10", "built in"])
    }

    @Test func onlyAConversationBeyondTheScreenIsOfferedForTextCapture() {
        #expect(ChatApps.offer(for: .beyondScreen) == .confirmWholeConversation)
        #expect(ChatApps.offer(for: .aboutAScreenful) == .keepScrolling)
        #expect(ChatApps.offer(for: .noText) == .nothing)
    }

    @Test func theFrontAppIsNeverTallshot() {
        var m = FrontAppMemory(own: 10, front: 10)
        #expect(m.pid == nil)
        m.activated(42); m.activated(10)
        #expect(m.pid == 42, "Tallshot's own Settings window coming forward doesn't count")
        m.terminated(7); #expect(m.pid == 42)
        m.terminated(42); #expect(m.pid == nil)
    }
}

@Suite("Windows open in front, on the display with the pointer")
struct WindowOpeningTests {
    let main = WindowOpening.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 944))
    let side = WindowOpening.Screen(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), visible: CGRect(x: 1512, y: -200, width: 2560, height: 1415))

    @Test func aNewWindowOpensCenteredOnThePointersDisplay() {
        let f = WindowOpening.frame(size: CGSize(width: 600, height: 400), pointer: CGPoint(x: 3000, y: 500), screens: [main, side], current: nil)
        #expect(side.visible.contains(f))
        #expect(abs(f.midX - side.visible.midX) <= 1)
    }

    @Test func anOpenWindowOnThatDisplayStaysPut() {
        let open = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(WindowOpening.frame(size: open.size, pointer: CGPoint(x: 700, y: 500), screens: [main, side], current: open) == open)
    }

    @Test func anOpenWindowOnAnotherDisplayMovesOver() {
        let open = CGRect(x: 100, y: 100, width: 600, height: 400)
        let f = WindowOpening.frame(size: open.size, pointer: CGPoint(x: 3000, y: 500), screens: [main, side], current: open)
        #expect(side.visible.contains(f) && f.size == open.size)
    }

    @Test func aTallWindowKeepsItsTitleBarOnScreen() {
        let f = WindowOpening.frame(size: CGSize(width: 520, height: 1200), pointer: CGPoint(x: 10, y: 10), screens: [main], current: nil)
        #expect(f.maxY == main.visible.maxY)
    }
}

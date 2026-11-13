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
        #expect(md.contains("```python\ndays = 3\nprint(days)\n```"), "the code exactly, its label as the fence's language")
        #expect(!md.contains("python\n\n```"), "the label isn't a paragraph of its own")
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
        #expect(r.turns.flatMap(\.blocks) == [.table([["City", "Days"], ["Lisbon", "2"]])])
        #expect(Markdown.render(ChatTranscript.document(r, assistantName: "ChatGPT")).contains("| City | Days |\n| --- | --- |\n| Lisbon | 2 |"))
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
        #expect(r.turns.flatMap(\.blocks) == [.listItem(level: 0, ordered: false, [Inline("Pack light.\nBring a jacket.")]),
                                               .code("zip -r bag.zip clothes", language: "bash")])
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

/// One test per finding of the 1.1.3 check (2026-11-10), with the structure from its reports
/// and from the ChatGPT app's own page code.
@Suite("1.1.3 re-check: what the ChatGPT and Claude captures showed")
struct RecheckTests {
    private func markdown(_ t: Tree, _ area: Int, app: String = "ChatGPT") -> (ChatReading, String) {
        let r = ChatTranscript.read(tree: t.tree, area: area)
        return (r, Markdown.render(ChatTranscript.document(r, assistantName: app)))
    }

    @Test func theAppsOwnInterfaceTextIsLeftOut() {
        var t = Tree()
        let (_, area) = t.window()
        let skip = t.add("AXLink", area, url: "#main")                     // ChatGPT's "Skip to content" link
        t.add("AXStaticText", skip, text: "Skip to content")
        let list = t.add("AXGroup", area)
        t.p(list, "Plan a trip")
        t.buttons(list, "Copy message", "Edit message")
        t.p(list, "Sure, here's a plan.")
        t.buttons(list, "Copy", "Good response", "Bad response")
        t.add("AXHeading", area, level: 2)                                  // invisible, before the message box
        t.add("AXStaticText", t.nodes.count - 1, text: "Latest response")
        t.p(area, "ChatGPT can make mistakes. Check important info.", classes: [])
        let (_, md) = markdown(t, area)
        for ui in ["Skip to content", "Latest response", "can make mistakes"] { #expect(!md.contains(ui), "\(ui)") }
        #expect(md.contains("Plan a trip") && md.contains("Sure, here's a plan."))
    }

    @Test func youSaidLabelsBecomeTheSpeakersAndArentRepeated() throws {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        for i in 0..<4 {
            t.add("AXHeading", list, level: 5, classes: ["sr-only"]); t.add("AXStaticText", t.nodes.count - 1, text: "You said:")
            t.p(list, "Question \(i)")
            t.buttons(list, "Copy message", "Edit message")
            t.add("AXHeading", list, level: 6, classes: ["sr-only"]); t.add("AXStaticText", t.nodes.count - 1, text: "ChatGPT said:")
            t.p(list, "Answer \(i)")
            t.buttons(list, "Copy", "Good response", "Bad response")
        }
        let (r, md) = markdown(t, area)
        #expect(r.rule == .labels)
        try #require(r.userTurns == 4 && r.replyTurns == 4)
        #expect(!md.contains("said:"), "only **You:** and **ChatGPT:**")
        #expect(md.components(separatedBy: "**You:**").count - 1 == 4 && md.components(separatedBy: "**ChatGPT:**").count - 1 == 4)
    }

    @Test func characterReferencesAreDecoded() {
        var t = Tree()
        let (_, area) = t.window()
        let p = t.add("AXGroup", area, classes: ["_Paragraph_xjxw3_2"])
        t.add("AXStaticText", p, text: "Sales &amp; Marketing, it&#39;s &lt;3 &#x2014; &quot;done&quot;, see ")
        let link = t.add("AXLink", p, url: "https://example.org/r?a=1&amp;b=2")
        t.add("AXStaticText", link, text: "Q&amp;A")
        let (r, md) = markdown(t, area)
        #expect(r.turns.flatMap(\.blocks) == [.paragraph([Inline("Sales & Marketing, it's <3 — \"done\", see "),
                                                          Inline("Q&A", link: "https://example.org/r?a=1&b=2")])])
        #expect(!md.contains("&amp;") && !md.contains("&#39;"))
        #expect(md.contains("(https://example.org/r?a=1&b=2)"))
    }

    @Test func noCharacterIsDroppedAndAddressesStayExact() {
        let text = "Track utm_source and snake_case_name, fill in $___ and _this_, see https://example.org/p?utm_source=x&utm_medium=y_z now"
        let md = Markdown.render(ExportDocument(blocks: [.paragraph([Inline(text)]),
                                                         .paragraph([Inline("the page", link: "https://example.org/a_b?utm_source=x&k=_v")])],
                                                source: .accessibility))
        #expect(md.contains("utm_source and snake_case_name"), "underscores inside words need no escape")
        #expect(md.contains("$\\_\\_\\_"), "a blank to fill in is kept, escaped")
        #expect(md.contains("https://example.org/p?utm_source=x&utm_medium=y_z now"), "a web address is copied exactly")
        #expect(md.contains("[the page](https://example.org/a_b?utm_source=x&k=_v)"))
        let line = md.split(separator: "\n").first { $0.hasPrefix("Track") }.map(String.init) ?? ""
        #expect(line.replacingOccurrences(of: "\\", with: "") == text, "removing the escapes gives back every character")
    }

    @Test func anAnalyzedPythonPanelIsAFencedCodeBlock() {
        var t = Tree()
        let (_, area) = t.window()
        let list = t.add("AXGroup", area)
        t.p(list, "Here is the analysis.")
        let root = t.add("AXGroup", list, classes: ["_Root_fab4p_2"])          // ChatGPT's code panel
        t.add("AXStaticText", root, text: "Analyzed")
        let surface = t.add("AXGroup", root, classes: ["_Surface_fab4p_2"])
        t.add("AXStaticText", surface, text: "Python")
        let code = t.add("AXGroup", surface, classes: ["_CodeSurface_fab4p_2"])
        for line in ["import pandas as pd", "df = pd.read_csv(\"sales_2026.csv\")", "print(df[\"total\"].sum())"] {
            let l = t.add("AXGroup", code)
            t.add("AXStaticText", l, text: line)
        }
        let bar = t.add("AXGroup", root, classes: ["_ActionBar_fab4p_2"])
        t.buttons(bar, "Copy")
        let (r, md) = markdown(t, area)
        #expect(r.turns.flatMap(\.blocks).last == .code("import pandas as pd\ndf = pd.read_csv(\"sales_2026.csv\")\nprint(df[\"total\"].sum())", language: "python"))
        #expect(md.contains("```python\nimport pandas as pd\ndf = pd.read_csv(\"sales_2026.csv\")\nprint(df[\"total\"].sum())\n```"))
        #expect(!md.contains("Analyzed") && !md.contains("\n`\n"), "no label paragraphs, no stray backtick")
    }

    @Test func headingClassesGetHeadingMarks() {
        var t = Tree()
        let (_, area) = t.window()
        let h = t.add("AXGroup", area, classes: ["_Heading_xjxw3_2"])
        t.add("AXStaticText", h, text: "Results")
        let h2 = t.add("AXGroup", area, classes: ["_Heading_xjxw3_2"])
        let inner = t.add("AXHeading", h2, level: 2)
        t.add("AXStaticText", inner, text: "Next steps")
        t.p(area, "Body text.")
        let (_, md) = markdown(t, area)
        #expect(md.contains("### Results") && md.contains("## Next steps"))
    }

    @Test func aChatGPTTableIsAMarkdownTable() {
        var t = Tree()
        let (_, area) = t.window()
        let box = t.add("AXGroup", area, classes: ["_TableContainer_xjxw3_2"])
        let table = t.add("AXTable", box, classes: ["_Table_xjxw3_2"])
        for (i, row) in [["Channel", "Revenue | share"], ["Brand Analytics", "$1,204"]].enumerated() {
            let r = t.add("AXRow", table)
            for c in row {
                let cell = t.add("AXCell", r, classes: [i == 0 ? "_TableHeaderCell_xjxw3_2" : "_TableCell_xjxw3_2"])
                t.add("AXStaticText", cell, text: c)
            }
        }
        let (_, md) = markdown(t, area)
        #expect(md.contains("| Channel | Revenue \\| share |\n| --- | --- |\n| Brand Analytics | $1,204 |"))
    }

    @Test func separateElementsDontRunTogether() {
        var t = Tree()
        let (_, area) = t.window()
        let p = t.add("AXGroup", area, classes: ["_Paragraph_xjxw3_2"])
        t.add("AXStaticText", p, text: "Open ")
        let a = t.add("AXGroup", p); t.add("AXStaticText", a, text: "Brand Analytics")
        let b = t.add("AXGroup", p); t.add("AXStaticText", b, text: "Export")
        t.add("AXStaticText", p, text: ", then save.")
        let (_, md) = markdown(t, area)
        #expect(md.contains("Open Brand Analytics Export, then save."))
    }

    @Test func claudesNavigationAndKeyboardHintsAreLeftOut() {
        var t = Tree()
        let (_, area) = t.window()
        let nav = t.add("AXGroup", area, subrole: "AXLandmarkNavigation")
        t.add("AXStaticText", nav, text: "Claude Navigation")
        let status = t.add("AXGroup", area, subrole: "AXApplicationStatus")
        t.add("AXStaticText", status, text: "Newest document available to open — press Tab to move to it")
        t.p(area, "Newest document available to open — press Tab to move to it", classes: [])
        t.p(area, "The real first message", classes: [])
        let (r, md) = markdown(t, area, app: "Claude")
        #expect(!md.contains("Navigation") && !md.contains("press Tab"))
        #expect(AppCheckPreview.first(r).hasPrefix("The real first message"))
    }

    @Test func aRepeatedSentenceIsKeptOnce() {
        var t = Tree()
        let (_, area) = t.window()
        t.p(area, "Let me know if you want a shorter version.", classes: [])
        t.p(area, "Let me know if you want a shorter version.", classes: [])
        t.p(area, "Glad that helped, enjoy the trip to Lisbon.Glad that helped, enjoy the trip to Lisbon.", classes: [])
        let blocks = ChatTranscript.read(tree: t.tree, area: area).turns.flatMap(\.blocks)
        #expect(blocks == [.paragraph([Inline("Let me know if you want a shorter version.")]),
                           .paragraph([Inline("Glad that helped, enjoy the trip to Lisbon.")])])
    }

    @Test func theChatGPTAppIsNotABrowserButBrowsersStayExcluded() {
        #expect(!BrowserCheck.isRealBrowser(bundleID: "com.openai.codex", opensWebLinks: true, opensWebPageFiles: false))
        #expect(!BrowserCheck.isRealBrowser(bundleID: "com.anthropic.claudefordesktop", opensWebLinks: false, opensWebPageFiles: false))
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox", "com.google.Chrome.canary"] {
            #expect(BrowserCheck.isRealBrowser(bundleID: id, opensWebLinks: false, opensWebPageFiles: false), "\(id)")
        }
        #expect(BrowserCheck.isRealBrowser(bundleID: "com.example.newbrowser", opensWebLinks: true, opensWebPageFiles: true))
    }

    @Test func theCheckIsWordedForAnyApp() {
        let chat = ChatReading(turns: [ChatTurn(speaker: .user, blocks: [.paragraph([Inline("Hi")])]),
                                       ChatTurn(speaker: .assistant, blocks: [.paragraph([Inline("Hello")])])], rule: .buttons)
        let plain = ChatReading(turns: [ChatTurn(speaker: nil, blocks: [.paragraph([Inline("Notes")])])], rule: .none)
        let c = CheckWording(verdict: .beyondScreen, appName: "ChatGPT", screens: 6.5, reading: chat)
        #expect(c.headline.contains("this chat") && c.firstLabel == "First message" && c.speakers?.contains("1 of yours") == true)
        let n = CheckWording(verdict: .beyondScreen, appName: "Notion", screens: 6.5, reading: plain)
        #expect(n.firstLabel == "First text" && n.lastLabel == "Last text" && n.speakers == nil)
        for words in [n.headline, n.explanation] { #expect(!words.contains("chat") && !words.contains("message"), "\(words)") }
        let a = CheckWording(verdict: .aboutAScreenful, appName: "Notion", screens: 0.8, reading: plain)
        #expect(!a.explanation.contains("chat"))
    }

    @Test func theCheckShowsYourFirstMessageNotATitle() {
        let r = ChatReading(turns: [ChatTurn(speaker: nil, blocks: [.paragraph([Inline("Lisbon trip")])]),
                                    ChatTurn(speaker: .user, blocks: [.paragraph([Inline("Plan a trip")])])], rule: .labels)
        #expect(CheckWording.firstTurn(r)?.speaker == .user)
    }
}

/// The first text Check This App shows (its preview, minus the speaker).
enum AppCheckPreview {
    static func first(_ r: ChatReading) -> String {
        CheckWording.firstTurn(r).map { $0.blocks.map(\.plainText).joined(separator: " ") } ?? ""
    }
}

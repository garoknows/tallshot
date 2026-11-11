import CoreGraphics
import Testing
@testable import TallshotCore

/// A pretend chat window: a sidebar list, a toolbar and the message column, each in its own
/// scroll area. Frames are all "on screen", as web apps report them.
private struct ChatWindow {
    var nodes: [ProbeNode] = []
    var texts: [Int: String] = [:]
    let pane = CGRect(x: 300, y: 60, width: 700, height: 800)

    @discardableResult
    mutating func add(_ role: String, parent: Int?, text: String? = nil, classes: [String] = []) -> Int {
        nodes.append(ProbeNode(role: role, frame: pane, textLength: text?.count ?? 0, classes: classes, parent: parent))
        if let text { texts[nodes.count - 1] = text }
        return nodes.count - 1
    }

    /// `messages` alternating You / Claude, each 300 characters.
    static func make(messages: Int, sidebarItems: Int = 40) -> ChatWindow {
        var w = ChatWindow()
        let window = w.add("AXWindow", parent: nil)
        let toolbar = w.add("AXScrollArea", parent: window)
        for i in 0..<12 { w.add("AXButton", parent: toolbar, text: "Button \(i)", classes: ["group/btn", "items-center"]) }
        let sidebar = w.add("AXScrollArea", parent: window)
        for i in 0..<sidebarItems { w.add("AXStaticText", parent: sidebar, text: "Chat title \(i)", classes: ["_TableCell_"]) }
        let column = w.add("AXScrollArea", parent: window)
        let list = w.add("AXGroup", parent: column, classes: ["flex-col"])
        for i in 0..<messages {
            let speaker = i % 2 == 0 ? "font-user-message" : "font-claude-message"
            let m = w.add("AXGroup", parent: list, classes: ["message", speaker])
            w.add("AXStaticText", parent: m, text: "Message \(i): " + String(repeating: "x", count: 288))
        }
        w.add("AXTextArea", parent: window)   // the empty message box
        return w
    }

    func report(_ tree: ProbeTree, area: Int) -> ProbeReport {
        ProbeReport.make(tree: tree, area: area, visible: pane, appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                         settledAfter: 800, cutShort: false)
    }
}

@Suite("Accessibility probe 2: judged by the text, not by frames")
struct TreeProbeTests {
    @Test func theMessageColumnIsPickedNotTheToolbarOrSidebar() {
        let w = ChatWindow.make(messages: 60)
        let tree = ProbeTree(w.nodes)
        let area = tree.messageArea()
        #expect(tree.nodes[tree.children[area].first!].classes == ["flex-col"], "the column holding the messages")
        let found = tree.messageList(in: area)
        #expect(found?.messages.count == 60)
        // The first and last message, in the tree's own order.
        let firstText = tree.inOrder(from: found!.messages.first!).compactMap { w.texts[$0] }.first
        let lastText = tree.inOrder(from: found!.messages.last!).compactMap { w.texts[$0] }.first
        #expect(firstText?.hasPrefix("Message 0:") == true && lastText?.hasPrefix("Message 59:") == true)
    }

    @Test func aLongConversationIsBeyondTheScreenEvenWithOnScreenFrames() {
        let w = ChatWindow.make(messages: 200)   // 60,000 characters; a screenful is about 5,000
        let tree = ProbeTree(w.nodes)
        let r = w.report(tree, area: tree.messageArea())
        #expect(r.verdict == .beyondScreen)
        #expect(r.screenfuls > 10 && r.messages == 200)
        #expect(r.messageClasses == ["message"])
        #expect(r.varyingClasses.map(\.name).sorted() == ["font-claude-message", "font-user-message"], "the speaker classes")
    }

    @Test func aScreenfulIsReportedAsSuch() {
        let w = ChatWindow.make(messages: 8)
        let tree = ProbeTree(w.nodes)
        #expect(w.report(tree, area: tree.messageArea()).verdict == .aboutAScreenful)
    }

    @Test func theReportHasNoTextFromTheApp() {
        let w = ChatWindow.make(messages: 50)
        let tree = ProbeTree(w.nodes)
        let t = w.report(tree, area: tree.messageArea()).text
        #expect(!t.contains("Message 0") && !t.contains("xxxxx") && !t.contains("Chat title"))
        #expect(t.contains("Messages (repeated containers): 50"))
        #expect(t.contains("the tree stopped growing after 800 ms"))
    }

    @Test func aTreeStillGrowingIsNotSettled() {
        #expect(!TreeSettling.settled(counts: [665]))
        #expect(!TreeSettling.settled(counts: [665, 759]))
        #expect(TreeSettling.settled(counts: [665, 759, 759]))
        #expect(!TreeSettling.settled(counts: [0, 0]))
    }
}

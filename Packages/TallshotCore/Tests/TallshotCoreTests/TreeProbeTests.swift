import CoreGraphics
import Testing
@testable import TallshotCore

/// A pretend chat pane 600 points tall, with messages 80 points apart.
@Suite("Accessibility probe: does the tree hold the whole conversation?")
struct TreeProbeTests {
    let pane = CGRect(x: 0, y: 100, width: 700, height: 600)

    func message(_ i: Int, classes: [String] = ["font-claude-message"]) -> ProbeNode {
        ProbeNode(role: "AXStaticText", frame: CGRect(x: 20, y: 100 + CGFloat(i) * 80, width: 600, height: 60), textLength: 120, classes: classes)
    }

    func report(_ nodes: [ProbeNode]) -> ProbeReport {
        ProbeReport.make(nodes: nodes, region: pane, appName: "Chat", bundleID: "com.example.chat", paneRole: "AXGroup", cutShort: false)
    }

    @Test func theWholeConversationRunsWithoutGaps() {
        // 200 messages from 60 screens up to the bottom, every one in the tree.
        let r = report((-180...7).map { message($0) })
        #expect(r.verdict == .continuous)
        #expect(r.above > 150 && r.onScreen > 0)
        #expect(r.textTop < -20 && r.largestGap < 1)
    }

    @Test func onlyTheMessagesNearTheScreen() {
        // A list that keeps a few messages around the screen (and drops the rest).
        let r = report((-3...10).map { message($0) })
        #expect(r.verdict == .nearScreenOnly)
    }

    @Test func aVirtualListLeavesEmptyStretches() {
        // Messages near the top and near the screen, with 40 screens of empty spacer between.
        let r = report((-300 ... -290).map { message($0) } + (-3...7).map { message($0) })
        #expect(r.verdict == .gaps)
        #expect(r.gapsOverOneScreen == 1 && r.largestGap > 30)
    }

    @Test func emptyPane() {
        #expect(report([ProbeNode(role: "AXGroup", frame: pane)]).verdict == .noText)
    }

    @Test func theReportHoldsNoTextOnlyShapeAndClassNames() {
        var nodes = (-50...7).map { message($0, classes: $0 % 2 == 0 ? ["font-user-message"] : ["font-claude-message", "prose"]) }
        nodes += [ProbeNode(role: "AXHeading", frame: nil), ProbeNode(role: "AXList", frame: nil),
                  ProbeNode(role: "AXListItem", frame: nil), ProbeNode(role: "AXGroup", frame: nil, classes: ["language-swift"])]
        let r = report(nodes)
        #expect(r.headings == 1 && r.lists == 1 && r.listItems == 1 && r.codeBlocks == 1)
        #expect(r.frequentClasses.map(\.name).prefix(3) == ["font-claude-message", "font-user-message", "prose"])
        let t = r.text
        #expect(t.contains("Verdict: Text runs well above and below the screen"))
        #expect(t.contains("font-user-message ×29"))
        // Class names longer than 40 characters (which could hold content) are left out.
        let long = report([ProbeNode(role: "AXStaticText", frame: pane, textLength: 3, classes: [String(repeating: "x", count: 41)])] +
                          (0..<3).map { _ in ProbeNode(role: "AXGroup", frame: nil, classes: [String(repeating: "x", count: 41)]) })
        #expect(long.frequentClasses.isEmpty)
    }
}

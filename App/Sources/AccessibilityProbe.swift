import AppKit
import ApplicationServices
import TallshotCore

/// `tallshot://probe`: checks whether the app under the pointer keeps its whole conversation in
/// its accessibility tree, or only what's near the screen. It turns on the app's full tree (the
/// same switch as a capture), walks the pane under the pointer including what's off screen, puts
/// a report with no text from the app on the clipboard, shows the first and last text it found
/// in the pop-up (for you to compare with the chat), and switches the extra tree back off. It only
/// reads: no pictures, no scrolling, no events, no files.
@MainActor
enum AccessibilityProbe {
    static let maxNodes = 60_000
    static let seconds = 12.0

    static func run() async {
        Toast.show(message: "Accessibility probe", detail: "Point at the conversation now. Starting in 3 seconds…", seconds: 3.5)
        try? await Task.sleep(for: .seconds(3))
        guard let (target, axSwitch) = await TargetFinder.find(at: TargetFinder.pointerLocation(), mode: .pane, waitMs: 1_500) else {
            Toast.show(message: "Accessibility probe", detail: "Nothing under the pointer.")
            return
        }
        defer { axSwitch?.restore() }
        guard target.pid != ProcessInfo.processInfo.processIdentifier else {
            Toast.show(message: "Accessibility probe", detail: "Point at another app's window, not Tallshot's.")
            return
        }
        // The pane's element, or the window's when no pane was found.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let root = target.textRoot ?? (TargetFinder.attribute(app, kAXFocusedWindowAttribute) as AXUIElement?)
        guard let root else {
            Toast.show(message: "Accessibility probe", detail: "The app shares no accessibility tree for this window.")
            return
        }
        var nodes: [ProbeNode] = []
        var first: (y: CGFloat, text: String)?, last: (y: CGFloat, text: String)?
        var queue = [root], i = 0
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while i < queue.count, nodes.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline {
            let el = queue[i]; i += 1
            AXUIElementSetMessagingTimeout(el, 0.5)
            let role = TargetFinder.string(el, kAXRoleAttribute) ?? ""
            let frame = TargetFinder.frame(el)
            var length = 0
            if role == "AXStaticText", let v: String = TargetFinder.attribute(el, kAXValueAttribute) {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                length = t.count
                if length > 0, let f = frame {
                    if first == nil || f.minY < first!.y { first = (f.minY, t) }
                    if last == nil || f.maxY > last!.y { last = (f.maxY, t) }
                }
            }
            let classes: [String] = TargetFinder.attribute(el, "AXDOMClassList") ?? []
            nodes.append(ProbeNode(role: role, frame: frame, textLength: length, classes: classes))
            queue += (TargetFinder.attribute(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        let report = ProbeReport.make(nodes: nodes, region: target.region, appName: target.appName, bundleID: target.bundleID ?? "unknown",
                                      paneRole: "\(target.kind.rawValue), \(TargetFinder.string(root, kAXRoleAttribute) ?? "?")",
                                      cutShort: i < queue.count)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.text, forType: .string)
        func snippet(_ s: String?) -> String { s.map { "“" + String($0.prefix(60)) + ($0.count > 60 ? "…”" : "”") } ?? "none" }
        Toast.show(message: "Probe report copied (no chat text in it).",
                   detail: "\(report.verdict.rawValue)\nFirst text: \(snippet(first?.text))\nLast text: \(snippet(last?.text))",
                   near: target.region, seconds: 25)
    }
}

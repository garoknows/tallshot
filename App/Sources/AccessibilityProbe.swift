import AppKit
import ApplicationServices
import SwiftUI
import TallshotCore

/// `tallshot://probe`: checks whether the app under the pointer keeps its whole conversation in
/// its accessibility tree, or only what's near the screen. It turns on the app's full tree (the
/// same switch as a capture), waits until the tree stops growing, walks the whole window, finds the
/// element holding the conversation (the scroll area with the most text) and the repeated
/// containers inside it (one per message), and compares the text it holds with what fits on
/// screen. Positions aren't trusted: web apps report off-screen elements as on screen. The result
/// window shows the first and last message for comparison with the chat; the copied report holds
/// no text from the app. It only reads: no pictures, no scrolling, no events, no files. The extra
/// tree is switched back off at the end.
@MainActor
enum AccessibilityProbe {
    static let maxNodes = 80_000
    static let walkSeconds = 15.0
    static let settleSeconds = 8.0

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
        guard let window = window(of: target) else {
            Toast.show(message: "Accessibility probe", detail: "The app shares no accessibility tree for this window.")
            return
        }
        Toast.show(message: "Accessibility probe", detail: "Reading the app's tree… keep the window as it is.", near: target.region, seconds: 30)

        // Wait until the tree stops growing (an Electron app builds it after the switch is turned on).
        let start = ProcessInfo.processInfo.systemUptime
        var counts: [Int] = []
        while ProcessInfo.processInfo.systemUptime - start < settleSeconds {
            counts.append(count(window))
            if TreeSettling.settled(counts: counts) { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        let settledAfter = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)

        // The whole window, parents before children, with each static text's value kept aside.
        var nodes: [ProbeNode] = [], texts: [Int: String] = [:]
        var queue: [(AXUIElement, Int?)] = [(window, nil)], i = 0
        let deadline = ProcessInfo.processInfo.systemUptime + walkSeconds
        while i < queue.count, nodes.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline {
            let (el, parent) = queue[i]; i += 1
            AXUIElementSetMessagingTimeout(el, 0.5)
            let role = TargetFinder.string(el, kAXRoleAttribute) ?? ""
            var length = 0
            if role == "AXStaticText", let v: String = TargetFinder.attribute(el, kAXValueAttribute), !v.isEmpty {
                length = v.count
                texts[nodes.count] = v
            }
            let classes: [String] = TargetFinder.attribute(el, "AXDOMClassList") ?? []
            let index = nodes.count
            nodes.append(ProbeNode(role: role, frame: TargetFinder.frame(el), textLength: length, classes: classes, parent: parent))
            for k in (TargetFinder.attribute(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { queue.append((k, index)) }
        }
        let tree = ProbeTree(nodes)
        let area = tree.messageArea()
        let visible = (nodes[area].frame ?? target.region).intersection(target.windowFrame)
        let report = ProbeReport.make(tree: tree, area: area, visible: visible.isNull ? target.region : visible,
                                      appName: target.appName, bundleID: target.bundleID ?? "unknown",
                                      settledAfter: settledAfter, cutShort: i < queue.count)
        let messages = tree.messageList(in: area)?.messages ?? []
        func words(_ m: Int?) -> String {
            guard let m else { return "none found" }
            let t = tree.inOrder(from: m).compactMap { texts[$0] }.joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return t.count > 200 ? String(t.prefix(200)) + "…" : t
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.text, forType: .string)
        Toast.hide()
        WindowRouter.shared.show("probe", title: "Accessibility Probe: \(target.appName)",
                                 ProbeResultView(report: report, first: words(messages.first), last: words(messages.last)))
    }

    /// The window being probed: the app's window with the target's frame, else its focused window.
    static func window(of target: CaptureTarget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let windows: [AXUIElement] = TargetFinder.attribute(app, kAXWindowsAttribute) ?? []
        if let w = windows.first(where: { TargetFinder.frame($0).map { abs($0.minX - target.windowFrame.minX) < 2 && abs($0.minY - target.windowFrame.minY) < 2 } ?? false }) {
            return w
        }
        return TargetFinder.attribute(app, kAXFocusedWindowAttribute)
    }

    /// How many elements the tree has now (a quick walk, at most 3 seconds).
    static func count(_ root: AXUIElement) -> Int {
        var queue = [root], i = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while i < queue.count, queue.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline {
            AXUIElementSetMessagingTimeout(queue[i], 0.5)
            queue += (TargetFinder.attribute(queue[i], kAXChildrenAttribute) as [AXUIElement]?) ?? []
            i += 1
        }
        return queue.count
    }
}

/// The probe's result. Stays open until closed.
struct ProbeResultView: View {
    let report: ProbeReport
    let first: String
    let last: String
    @State private var copied = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.verdict.rawValue).font(.headline).fixedSize(horizontal: false, vertical: true)
            Group {
                Text("First message in the tree").font(.subheadline.weight(.semibold))
                Text(first).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Last message in the tree").font(.subheadline.weight(.semibold))
                Text(last).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Is the first one the chat's real first message? These two are shown only here; the copied report has no chat text.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Button(copied ? "Report Copied" : "Copy Report") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    copied = pb.setString(report.text, forType: .string)
                }
                Spacer()
                Button("Close") { WindowRouter.shared.close("probe") }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

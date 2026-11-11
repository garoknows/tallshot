import AppKit
import ApplicationServices
import SwiftUI
import TallshotCore

/// Menu → Troubleshooting → Check This App…: does the app that was in front before the menu
/// opened keep its whole conversation in its accessibility tree, or only what's near the screen?
/// It turns on the app's full tree (the same switch as a capture), waits until the tree stops
/// growing, walks the whole front window, finds the conversation (the widest scroll area holding
/// a good share of the text) and compares the text it holds with what fits on screen. Positions
/// aren't trusted: web apps report off-screen elements as on screen. The result window shows the
/// first and last message, with who said them, and the user decides; the answer is remembered
/// for that app (Settings → General → Chat apps). Only reads: no pictures, no scrolling, no
/// events, no files. The extra tree is switched back off at the end. Started from the menu
/// (also `tallshot://check`), never from the pointer.
@MainActor
enum AppCheck {
    static let maxNodes = 80_000
    static let walkSeconds = 15.0
    static let settleSeconds = 8.0

    static func run(pid: pid_t?) async {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let pid, pid != own, let front = TargetFinder.windowList().first(where: { $0.pid == pid }) else {
            Toast.show(message: "Check This App", detail: "Click the app's window first, then choose Check This App… in the Tallshot menu.")
            return
        }
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier
        let name = running?.localizedName ?? front.owner
        let axSwitch = AccessibilitySwitch(pid: pid, bundleID: bundleID)
        defer { axSwitch.restore() }
        guard let window = TreeWalker.window(pid: pid, frame: front.bounds) else {
            Toast.show(message: "Check This App: \(name)", detail: "The app shares no accessibility tree for this window.")
            return
        }
        Toast.show(message: "Checking \(name)…", detail: "Reading its accessibility tree. Keep the window as it is.", near: front.bounds, seconds: 30)
        let settledAfter = await TreeWalker.settle(window, seconds: settleSeconds)
        let walk = await TreeWalker.walk(window, maxNodes: maxNodes, seconds: walkSeconds)
        let tree = walk.tree
        let area = tree.messageArea()
        let visible = (tree.nodes[area].frame ?? front.bounds).intersection(front.bounds)
        let reading = ChatTranscript.read(tree: tree, area: area)
        let report = ProbeReport.make(tree: tree, area: area, visible: visible.isNull ? front.bounds : visible,
                                      appName: name, bundleID: bundleID ?? "unknown",
                                      settledAfter: settledAfter, cutShort: !walk.complete, reading: reading)
        Toast.hide()
        // A browser shows every kind of site, some keeping only what's near the screen: one
        // answer for the whole browser can't be right, so it isn't offered.
        let browser = TargetFinder.isWebBrowser(bundleID: bundleID, app: running)
        WindowRouter.shared.show("check", title: "Check This App: \(name)",
                                 AppCheckView(report: report, bundleID: browser ? nil : bundleID, appName: name, isBrowser: browser,
                                              first: preview(reading.turns.first, appName: name),
                                              last: preview(reading.turns.last, appName: name),
                                              settings: Settings.shared),
                                 replace: true)
    }

    /// "You: the first 200 characters…", for comparing with the chat. Shown only in the window.
    static func preview(_ turn: ChatTurn?, appName: String) -> String {
        guard let turn else { return "none found" }
        let words = turn.blocks.map(\.plainText).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let short = words.count > 200 ? String(words.prefix(200)) + "…" : words
        switch turn.speaker {
        case .user: return "You: " + short
        case .assistant: return "\(appName): " + short
        case nil: return short
        }
    }
}

/// The check's result. Stays open until closed.
struct AppCheckView: View {
    let report: ProbeReport
    let bundleID: String?
    let appName: String
    var isBrowser = false
    let first: String
    let last: String
    @ObservedObject var settings: Settings
    @State private var copied = false

    var offer: ChatApps.Offer { ChatApps.offer(for: report.verdict) }

    var screens: String {
        let r = (report.screenfuls * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : "\(r)"
    }

    var headline: String {
        switch report.verdict {
        case .beyondScreen: "\(appName) keeps about \(screens) screens of this chat, much more than fits on screen."
        case .aboutAScreenful: "\(appName) keeps only about \(screens) screen\(screens == "1" ? "" : "s") of this chat."
        case .noText: "Tallshot found no conversation text in this window."
        }
    }

    var explanation: String {
        switch report.verdict {
        case .beyondScreen:
            "If the first message below is this chat's real first message (scroll to the top of the chat to compare), \(appName) keeps the whole conversation, and Tallshot can copy it as text with no scrolling."
        case .aboutAScreenful:
            "If this chat is longer than one screen, \(appName) keeps only what's near the screen, so Tallshot keeps taking scrolling screenshots. If the chat really is this short, close this and check a longer one."
        case .noText:
            "Open a chat in the app, click its window, then choose Check This App… again."
        }
    }

    var status: String {
        let text = ChatApps.usesText(bundleID: bundleID, checked: settings.checkedApps)
        return "Now: captures of \(appName) \(text ? "copy the whole conversation as text" : "take a scrolling screenshot")."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            if isBrowser {
                Text("\(appName) is a browser: each site keeps its text differently, so Tallshot always takes a scrolling screenshot in browsers.")
                    .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            if offer != .nothing {
                Group {
                    Text("First message").font(.subheadline.weight(.semibold))
                    Text(first).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Last message").font(.subheadline.weight(.semibold))
                    Text(last).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let s = report.speakers {
                    Text("Who said what: \(s.rule.note) (\(s.yours) of yours, \(s.replies) replies).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("The messages are shown only here. The report has no chat text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Report") {
                ScrollView {
                    Text(report.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            if bundleID != nil { Text(status).font(.callout.weight(.medium)) }
            HStack {
                Button(copied ? "Report Copied" : "Copy Report") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    copied = pb.setString(report.text, forType: .string)
                }
                Spacer()
                if let id = bundleID {
                    switch offer {
                    case .confirmWholeConversation:
                        Button("No, Keep Scrolling Screenshots") { settings.rememberChatApp(id, name: appName, wholeConversation: false) }
                        Button("Yes, Use Text Capture") { settings.rememberChatApp(id, name: appName, wholeConversation: true) }
                            .keyboardShortcut(.defaultAction)
                    case .keepScrolling:
                        Button("Keep Scrolling Screenshots") { settings.rememberChatApp(id, name: appName, wholeConversation: false) }
                    case .nothing:
                        EmptyView()
                    }
                }
                Button("Close") { WindowRouter.shared.close("check") }
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

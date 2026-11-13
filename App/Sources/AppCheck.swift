import AppKit
import ApplicationServices
import SwiftUI
import TallshotCore
import UniformTypeIdentifiers

/// Menu → Troubleshooting → Check This App…: does the app that was in front before the menu
/// opened keep its whole conversation in its accessibility tree, or only what's near the screen?
/// It turns on the app's full tree (the same switch as a capture), waits until the tree stops
/// growing, walks the whole front window, finds the conversation (the widest scroll area holding
/// a good share of the text) and compares the text it holds with what fits on screen. Positions
/// aren't trusted: web apps report off-screen elements as on screen. The result window shows the
/// first and last message, with who said them, and the user decides; the answer is remembered
/// for that app (Settings → General → Apps). Only reads: no pictures, no scrolling, no
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
        let browser = isRealBrowser(bundleID: bundleID, app: running)
        let first = CheckWording.firstTurn(reading)
        WindowRouter.shared.show("check", title: "Check This App: \(name)",
                                 AppCheckView(report: report, bundleID: browser ? nil : bundleID, appName: name, isBrowser: browser,
                                              wording: CheckWording(verdict: report.verdict, appName: name, screens: report.screenfuls, reading: reading),
                                              isChat: reading.isChat,
                                              first: preview(first, appName: name),
                                              last: preview(reading.turns.last, appName: name),
                                              settings: Settings.shared),
                                 replace: true)
    }

    /// A real web browser: known by name, or an app that opens both web links and web pages saved
    /// as files. (The ChatGPT app opens web links but is not a browser.)
    static func isRealBrowser(bundleID: String?, app: NSRunningApplication?) -> Bool {
        guard let bundle = app?.bundleURL?.standardizedFileURL, let web = URL(string: "https://example.com") else {
            return BrowserCheck.isRealBrowser(bundleID: bundleID, opensWebLinks: false, opensWebPageFiles: false)
        }
        let links = NSWorkspace.shared.urlsForApplications(toOpen: web).contains { $0.standardizedFileURL == bundle }
        let pages = NSWorkspace.shared.urlsForApplications(toOpen: UTType.html).contains { $0.standardizedFileURL == bundle }
        return BrowserCheck.isRealBrowser(bundleID: bundleID, opensWebLinks: links, opensWebPageFiles: pages)
    }

    /// "You: the first 200 characters…", for comparing with the app. Shown only in the window.
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

/// The check's result. Stays open until closed. Worded for a chat when speakers were found,
/// neutrally ("text") for any other app.
struct AppCheckView: View {
    let report: ProbeReport
    let bundleID: String?
    let appName: String
    var isBrowser = false
    let wording: CheckWording
    let isChat: Bool
    let first: String
    let last: String
    @ObservedObject var settings: Settings
    @State private var copied = false

    var offer: ChatApps.Offer { ChatApps.offer(for: report.verdict) }

    var status: String {
        let text = ChatApps.usesText(bundleID: bundleID, checked: settings.checkedApps)
        let copies = isChat ? "copy the whole conversation as text" : "copy all of its text"
        return "Now: captures of \(appName) \(text ? copies : "take a scrolling screenshot")."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wording.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(wording.explanation).fixedSize(horizontal: false, vertical: true)
            if isBrowser {
                Text("\(appName) is a web browser: each site keeps its text differently, so Tallshot always takes a scrolling screenshot in browsers.")
                    .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            if offer != .nothing {
                Group {
                    Text(wording.firstLabel).font(.subheadline.weight(.semibold))
                    Text(first).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(wording.lastLabel).font(.subheadline.weight(.semibold))
                    Text(last).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let s = wording.speakers {
                    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("This text is shown only here. The report has none of it.")
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

import AppKit
import ApplicationServices
import TallshotCore

/// A text capture of a chat app whose accessibility tree holds the whole conversation (ChatGPT,
/// or an app Check This App confirmed): every message, with who said it, read from the tree with
/// no scrolling and no pictures. Only reads. See `ChatApps` for which apps, and `ChatTranscript`.
@MainActor
enum ChatTextReader {
    struct Result {
        var document: ExportDocument?
        var reading: ChatReading?
        /// Why there's no document, for the pop-up of the scrolling screenshot taken instead.
        var why: String?
    }

    /// The same limit as Check This App, so a chat the check passes can also be captured.
    static let walkSeconds = AppCheck.walkSeconds

    static func read(_ target: CaptureTarget) async -> Result {
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return Result(why: "this is Tallshot's own window.") }
        guard let window = TreeWalker.window(pid: target.pid, frame: target.windowFrame) else {
            return Result(why: "the app shares no accessibility tree for this window.")
        }
        Toast.show(message: "Reading the conversation…", detail: "From \(target.appName), with no scrolling.", near: target.region, seconds: 30)
        // The app builds its tree when the capture turns its accessibility switch on.
        _ = await TreeWalker.settle(window, seconds: 4)
        let walk = await TreeWalker.walk(window, seconds: walkSeconds)
        Toast.hideNow()   // it could sit over the pane if a scrolling screenshot follows
        guard !walk.cutShort else { return Result(why: "the conversation was too long to read in \(Int(walkSeconds)) seconds.") }
        guard walk.failed == 0 else { return Result(why: "\(target.appName) didn't answer for part of the conversation.") }
        let area = walk.tree.messageArea(near: target.center)
        let reading = ChatTranscript.read(tree: walk.tree, area: area)
        guard reading.hasText else { return Result(why: "no conversation text was found in this window.") }
        return Result(document: ChatTranscript.document(reading, assistantName: target.appName), reading: reading)
    }
}

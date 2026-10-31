import AppKit
import SwiftUI
import TallshotCore

/// The built-in test page: every point row carries its row number as a barcode, next to real
/// text, inside a real scroll view with a sticky toolbar and a message box on top of it.
final class SelfTestDocument: NSView {
    let rows: Int
    init(width: CGFloat, rows: Int) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill()
        dirty.fill()
        let first = max(0, Int(dirty.minY)), last = min(rows, Int(dirty.maxY.rounded(.up)))
        NSColor.black.setFill()
        for y in first..<last {
            for (c, dark) in Barcode.cells(for: y).enumerated() where dark {
                NSRect(x: CGFloat(TestPage.barcodeX + c * TestPage.cellWidth), y: CGFloat(y), width: CGFloat(TestPage.cellWidth), height: 1).fill()
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.22, alpha: 1)]
        let x = CGFloat(TestPage.barcodeX + TestPage.barcodeWidth + 12)
        for line in max(0, first / 22 - 1)...(last / 22 + 1) {
            ("Row \(line + 1) of \(rows / 22): every row must appear once, in order." as NSString)
                .draw(at: NSPoint(x: x, y: CGFloat(line * 22 + 3)), withAttributes: attrs)
        }
    }
}

final class SelfTestBar: NSView {
    let color: NSColor, label: String
    init(color: NSColor, label: String) { self.color = color; self.label = label; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        color.setFill(); bounds.fill()
        (label as NSString).draw(at: NSPoint(x: 12, y: (bounds.height - 16) / 2),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
    }
}

@MainActor
final class SelfTestState: ObservableObject {
    enum Phase: Equatable { case idle, running, passed(String), failed(String) }
    @Published var phase: Phase = .idle
}

/// Opens the test page and runs a real end-to-end capture of it: Accessibility finds the
/// scroll area, ScreenCaptureKit takes the pictures, scroll events move it, the engine stitches.
/// Then it reads every row's barcode back and checks each came out once, in order.
@MainActor
final class SelfTest {
    static let shared = SelfTest()
    let rows = 2400
    let toolbarHeight: CGFloat = 44, inputHeight: CGFloat = 56
    let state = SelfTestState()
    private var window: NSWindow?
    private var scrollView: NSScrollView?

    func run() {
        guard Permissions.allGranted else { WindowRouter.shared.showSetup(); return }
        guard state.phase != .running else { return }
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        state.phase = .running
        Task { await runCapture() }
    }

    private func makeWindow() -> NSWindow {
        let width: CGFloat = 520, pageHeight: CGFloat = 560, panel: CGFloat = 84
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: pageHeight + panel), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Tallshot Self-Test"
        w.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: pageHeight + panel))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: pageHeight))
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .white
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: toolbarHeight, left: 0, bottom: inputHeight, right: 0)
        sv.documentView = SelfTestDocument(width: width, rows: rows)
        let toolbar = SelfTestBar(color: Brand.liftNS, label: "Sticky toolbar: should appear once, at the top")
        toolbar.frame = NSRect(x: 0, y: pageHeight - toolbarHeight, width: width, height: toolbarHeight)
        let input = SelfTestBar(color: NSColor(srgbRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255, alpha: 1),
                                label: "Message box: should appear once, at the bottom")
        input.frame = NSRect(x: 0, y: 0, width: width, height: inputHeight)
        sv.addSubview(toolbar)
        sv.addSubview(input)
        root.addSubview(sv)
        let status = NSHostingView(rootView: SelfTestStatusView(state: state, rows: rows))
        status.frame = NSRect(x: 0, y: pageHeight, width: width, height: panel)
        root.addSubview(status)
        w.contentView = root
        w.center()
        scrollView = sv
        return w
    }

    private func runCapture() async {
        guard let w = window, let sv = scrollView else { return }
        // Start at the top of the page.
        sv.contentView.scroll(to: NSPoint(x: 0, y: -toolbarHeight))
        sv.reflectScrolledClipView(sv.contentView)
        try? await Task.sleep(for: .milliseconds(400))

        let frameOnScreen = w.convertToScreen(sv.convert(sv.bounds, to: nil))
        let topLeft = CGRect(x: frameOnScreen.minX, y: TargetFinder.mainHeight - frameOnScreen.maxY,
                             width: frameOnScreen.width, height: frameOnScreen.height)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let target = TargetFinder.find(at: CGPoint(x: topLeft.midX, y: topLeft.midY), onlyPID: pid) else {
            state.phase = .failed("Couldn't find the test window on screen.")
            return
        }
        let start = Date()
        do {
            let (result, capturer) = try await AppModel.run(target: target, options: Settings.shared.captureOptions(fromTop: false))
            let seconds = Date().timeIntervalSince(start)
            state.phase = verdict(result, scale: capturer.scale, target: target, seconds: seconds)
        } catch {
            state.phase = .failed("Capture failed: \(error.localizedDescription)")
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func verdict(_ r: CaptureResult, scale: CGFloat, target: CaptureTarget, seconds: Double) -> SelfTestState.Phase {
        let s = Int(scale.rounded())
        let report = BarcodeReport.read(r.image, originX: Double(TestPage.barcodeX * s), cellWidth: Double(TestPage.cellWidth * s), pixelsPerRow: s)
        let time = String(format: "%.1f s", seconds)
        if !target.isScrollArea { return .failed("Accessibility didn't report the scroll area (used the whole window).") }
        if r.reason != .bottom { return .failed("Stopped early (\(r.reason.rawValue)) after \(report.distinctRows) of \(rows) rows, \(time).") }
        guard report.isClean, report.first == 0, report.last == rows - 1 else {
            var why: [String] = []
            if !report.missing.isEmpty { why.append("\(report.missing.count) rows missing") }
            if !report.repeated.isEmpty { why.append("\(report.repeated.count) rows repeated") }
            if report.outOfOrder > 0 { why.append("\(report.outOfOrder) out of order") }
            if report.first != 0 { why.append("first row \(report.first.map(String.init) ?? "none")") }
            if report.last != rows - 1 { why.append("last row \(report.last.map(String.init) ?? "none")") }
            return .failed("Rows didn't line up: \(why.joined(separator: ", ")). \(time).")
        }
        // The toolbar and the message box must each appear once.
        let expected = (Int(toolbarHeight) + rows + Int(inputHeight)) * s
        if abs(r.image.height - expected) > 2 * s {
            return .failed("Height \(r.image.height) px, expected \(expected) px: a fixed bar was repeated or cut. \(time).")
        }
        return .passed("All \(rows) rows came out once, in order. Toolbar and message box once each. \(Delivery.pixels(r.image.height)) in \(time).")
    }
}

struct SelfTestStatusView: View {
    @ObservedObject var state: SelfTestState
    var rows: Int

    var body: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .idle, .running:
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running the self-test…").font(.headline)
                    Text("Hands off the mouse and keyboard for a few seconds.").font(.callout).foregroundStyle(.secondary)
                }
            case .passed(let msg):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passed").font(.headline)
                    Text(msg).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill").font(.system(size: 26)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Failed").font(.headline)
                    Text(msg).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if state.phase != .running {
                Button("Run Again") { SelfTest.shared.run() }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.paper.opacity(0.6))
    }
}

import AppKit
import ScreenCaptureKit
import TallshotCore

enum CaptureError: LocalizedError {
    case windowGone, captureFailed
    var errorDescription: String? {
        switch self {
        case .windowGone: "That window closed or moved off screen."
        case .captureFailed: "macOS didn't return a picture of that window."
        }
    }
}

/// Takes pictures of one window, cropped to the capture region, with ScreenCaptureKit.
/// Other windows on top don't get in the way, because only that window is captured.
@MainActor
final class WindowCapturer {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let pixelWidth: Int, pixelHeight: Int
    let scale: CGFloat
    private(set) var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(target: CaptureTarget) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else { throw CaptureError.windowGone }
        filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        let wf = window.frame
        config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: target.region.minX - wf.minX, y: target.region.minY - wf.minY,
                                   width: target.region.width, height: target.region.height)
        pixelWidth = Int((target.region.width * scale).rounded())
        pixelHeight = Int((target.region.height * scale).rounded())
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
    }

    /// One frame as BGRA pixels. Held in memory only; never written anywhere.
    func capture() async throws -> PixelImage {
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let cs = cg.colorSpace { colorSpace = cs }
        return try Self.pixels(from: cg, width: pixelWidth, height: pixelHeight, colorSpace: colorSpace)
    }

    static func pixels(from cg: CGImage, width: Int, height: Int, colorSpace: CGColorSpace) throws -> PixelImage {
        var px = [UInt32](repeating: 0, count: width * height)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw CaptureError.captureFailed }
        return PixelImage(width: width, height: height, pixels: px)
    }
}

/// Posts scroll events built by `ScrollEvents` (private source, no modifier keys, proper phases).
@MainActor
enum ScrollPoster {
    static var marker: Int64 { ScrollEvents.marker }

    /// Scrolls the content under `point` up by `points` (negative scrolls back toward the top).
    static func scroll(points: Int, at point: CGPoint, inverted: Bool, method: ScrollMethod) async {
        let events = ScrollEvents.make(points: points, at: point, inverted: inverted, method: method)
        for (i, e) in events.enumerated() {
            e.post(tap: .cghidEventTap)
            if i < events.count - 1 { try? await Task.sleep(for: .milliseconds(8)) }
        }
    }
}

/// Moves a scroll area by setting its scroll bar through Accessibility: exact, no animation,
/// no momentum. The value runs from 0 (top) to 1 (bottom).
@MainActor
struct ScrollBarMover {
    let bar: AXUIElement
    /// Points of content per whole 0...1 range. Starts from what the app reports (or a guess
    /// of ten screens); the capture loop corrects for any error by measuring each step.
    let range: CGFloat

    init(bar: AXUIElement, contentHeight: CGFloat?, visibleHeight: CGFloat) {
        self.bar = bar
        let extra = (contentHeight ?? 0) - visibleHeight
        range = extra > visibleHeight * 0.2 ? extra : visibleHeight * 10
    }

    var value: Double? {
        let n: NSNumber? = TargetFinder.attribute(bar, kAXValueAttribute)
        return n?.doubleValue
    }

    /// Returns false if the app refused.
    func move(points: Int) -> Bool {
        guard let v = value else { return false }
        let next = min(1, max(0, v + Double(points) / Double(range)))
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) == .success
    }
}

/// The real-world `CaptureDriver`: ScreenCaptureKit pictures, scroll events (or the scroll bar)
/// at the scroll point, and a watch for Esc, clicks, keys or mouse movement that cancel.
@MainActor
final class LiveDriver: CaptureDriver {
    let target: CaptureTarget
    let capturer: WindowCapturer
    private var monitors: [Any] = []
    private var cancelledByUser = false
    private var pointerMoved = false
    private var inverted = false
    private let savedPointer: CGPoint
    private(set) var method = ScrollMethod.gesture
    private let mover: ScrollBarMover?
    /// Reads the pane's text at each step, when an export needs it.
    var collector: TextCollector?

    func contentSettled() { collector?.snapshot() }

    init(target: CaptureTarget, capturer: WindowCapturer) {
        self.target = target
        self.capturer = capturer
        savedPointer = TargetFinder.pointerLocation()
        let own = target.pid == ProcessInfo.processInfo.processIdentifier
        mover = (own ? nil : target.scrollBar).map { ScrollBarMover(bar: $0, contentHeight: target.contentHeight, visibleHeight: target.region.height) }
    }

    var isCancelled: Bool { cancelledByUser }
    var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Moves the pointer to the scroll point and starts watching for the user.
    func begin() {
        CGWarpMouseCursorPosition(target.scrollPoint)
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] e in self?.userEvent(e) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) { monitors.append(m) }
    }

    /// Stops watching and puts the pointer back where it was (unless the user moved it).
    func end() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if !pointerMoved { CGWarpMouseCursorPosition(savedPointer) }
    }

    private func userEvent(_ e: NSEvent) {
        switch e.type {
        case .scrollWheel:
            if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScrollPoster.marker { return }
            cancelledByUser = true
        case .mouseMoved, .leftMouseDragged:
            let p = TargetFinder.pointerLocation()
            if hypot(p.x - target.scrollPoint.x, p.y - target.scrollPoint.y) > 8 { cancelledByUser = true; pointerMoved = true }
        default:
            cancelledByUser = true
            if e.type != .keyDown { pointerMoved = true }
        }
    }

    func captureFrame() async throws -> PixelImage { try await capturer.capture() }

    func setScrollMethod(_ m: ScrollMethod) -> Bool {
        if m == .scrollBar && mover == nil { return false }
        method = m
        return true
    }

    func scroll(pixels: Int) async throws {
        let points = Int((CGFloat(pixels) / capturer.scale).rounded())
        guard points != 0 else { return }
        if method == .scrollBar, let mover {
            // The scroll bar runs top to bottom; a flipped direction flips it too.
            _ = mover.move(points: inverted ? -points : points)
            return
        }
        await ScrollPoster.scroll(points: points, at: target.scrollPoint, inverted: inverted, method: method)
    }

    func reverseScrollDirection() { inverted.toggle() }

    func pause(milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
}

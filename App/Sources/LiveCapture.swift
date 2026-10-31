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

    /// Turns a finished capture back into a CGImage in the screen's color space.
    static func cgImage(_ img: PixelImage, colorSpace: CGColorSpace) -> CGImage? {
        let data = img.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Sends scroll-wheel events, the same signal a trackpad sends.
@MainActor
enum ScrollPoster {
    /// Marks Tallshot's own events so the cancel monitor can tell them from the user's.
    static let marker: Int64 = 0x5441_4C4C   // "TALL"

    /// Scrolls the content under `point` up by `points` (negative scrolls back toward the top).
    static func scroll(points: Int, at point: CGPoint, inverted: Bool) async {
        let source = CGEventSource(stateID: .hidSystemState)
        var left = abs(points)
        let direction: Int32 = (points > 0) != inverted ? -1 : 1
        while left > 0 {
            let chunk = min(left, 240)
            left -= chunk
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: direction * Int32(chunk), wheel2: 0, wheel3: 0) else { return }
            e.location = point
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
            if left > 0 { try? await Task.sleep(for: .milliseconds(8)) }
        }
    }
}

/// The real-world `CaptureDriver`: ScreenCaptureKit pictures, scroll-wheel events at the
/// middle of the region, and a watch for Esc, clicks, keys or mouse movement that cancel.
@MainActor
final class LiveDriver: CaptureDriver {
    let target: CaptureTarget
    let capturer: WindowCapturer
    private var monitors: [Any] = []
    private var cancelledByUser = false
    private var pointerMoved = false
    private var inverted = false
    private let savedPointer: CGPoint

    init(target: CaptureTarget, capturer: WindowCapturer) {
        self.target = target
        self.capturer = capturer
        savedPointer = TargetFinder.pointerLocation()
    }

    var isCancelled: Bool { cancelledByUser }
    var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Moves the pointer to the middle of the region and starts watching for the user.
    func begin() {
        CGWarpMouseCursorPosition(target.center)
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
            if hypot(p.x - target.center.x, p.y - target.center.y) > 8 { cancelledByUser = true; pointerMoved = true }
        default:
            cancelledByUser = true
            if e.type != .keyDown { pointerMoved = true }
        }
    }

    func captureFrame() async throws -> PixelImage { try await capturer.capture() }

    func scroll(pixels: Int) async throws {
        let points = Int((CGFloat(pixels) / capturer.scale).rounded())
        await ScrollPoster.scroll(points: points, at: target.center, inverted: inverted)
    }

    func reverseScrollDirection() { inverted.toggle() }

    func pause(milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
}

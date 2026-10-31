/// What the capture loop needs from the outside world. The app implements it with
/// ScreenCaptureKit and scroll-wheel events; the tests implement it with generated pages.
@MainActor
public protocol CaptureDriver: AnyObject {
    /// A picture of the capture region right now.
    func captureFrame() async throws -> PixelImage
    /// Scrolls the region's content up by about `pixels` (negative scrolls back toward the top).
    func scroll(pixels: Int) async throws
    /// Waits a moment (lets smooth scrolling and animations run).
    func pause(milliseconds: Int) async
    /// True once the user pressed Esc or touched the mouse or keyboard.
    var isCancelled: Bool { get }
    /// A clock in seconds, for the time cap.
    var now: Double { get }
    /// Called when a scroll moved the page the wrong way (for example a system setting flipped
    /// it); every later scroll should go the other way.
    func reverseScrollDirection()
}

public extension CaptureDriver {
    func reverseScrollDirection() {}
}

public struct CaptureOptions: Sendable, Equatable {
    /// Scroll step as a share of the moving area's height, once the fixed bands are known.
    public var stepFraction = 0.8
    /// The first step, before the header and footer are known.
    public var firstStepFraction = 0.5
    /// Stop at this many pixels tall.
    public var maxHeight = 30_000
    /// Stop after this many seconds.
    public var maxSeconds = 60.0
    /// Time between the two quick captures that confirm the page has settled.
    public var settleIntervalMs = 50
    /// Give up waiting for the page to settle after this many tries (an animation that never stops).
    public var maxSettleTries = 8
    /// Scroll to the top first, then capture the whole thing.
    public var fromTop = false

    public init() {}
}

public enum StopReason: String, Sendable, Equatable {
    /// Reached the bottom: a scroll moved nothing, twice in a row.
    case bottom
    case heightCap
    case timeCap
    case cancelled
    /// A step could not be lined up even after waiting and a smaller step; kept what was safe.
    case lostTrack

    /// Whether the capture ended before the page did.
    public var isEarly: Bool { self != .bottom }
}

public struct CaptureResult: Sendable {
    public var image: PixelImage
    public var reason: StopReason
    public var steps: Int
    public var frames: Int
    public var seconds: Double
}

/// Runs one scrolling capture from start to finish.
@MainActor
public final class CaptureSession {
    public let driver: CaptureDriver
    public let options: CaptureOptions
    public let aligner: FrameAligner
    public private(set) var frames = 0

    public init(driver: CaptureDriver, options: CaptureOptions = CaptureOptions(), aligner: FrameAligner = FrameAligner()) {
        self.driver = driver
        self.options = options
        self.aligner = aligner
    }

    public func run() async throws -> CaptureResult {
        let start = driver.now
        if options.fromTop { try await scrollToTop() }

        let first = try await settledFrame()
        var stitcher = Stitcher(first: first)
        let H = first.height
        var step = max(1, Int(Double(H) * options.firstStepFraction))
        var still = 0
        var recoveries = 0
        var directionChecked = options.fromTop

        func finish(_ reason: StopReason) -> CaptureResult {
            if stitcher.image.height > options.maxHeight { stitcher.cap(height: options.maxHeight) }
            return CaptureResult(image: stitcher.image, reason: reason, steps: stitcher.steps, frames: frames, seconds: driver.now - start)
        }

        while true {
            if driver.isCancelled { return finish(.cancelled) }
            if stitcher.image.height >= options.maxHeight { return finish(.heightCap) }
            if driver.now - start >= options.maxSeconds { return finish(.timeCap) }

            try await driver.scroll(pixels: step)
            var frame = try await settledFrame()
            if driver.isCancelled { return finish(.cancelled) }

            var result = aligner.align(stitcher.last, frame, expected: step)
            var wait = options.settleIntervalMs * 3
            for _ in 0..<3 {
                guard case .uncertain = result else { break }
                // Content may still have been moving, or a popup was passing: wait, look again.
                await driver.pause(milliseconds: wait)
                wait *= 2
                frame = try await settledFrame()
                if driver.isCancelled { return finish(.cancelled) }
                result = aligner.align(stitcher.last, frame, expected: step)
            }

            if !directionChecked {
                directionChecked = true
                if result == .noMovement || { if case .uncertain = result { return true } else { return false } }(),
                   case .moved = aligner.align(frame, stitcher.last, expected: step) {
                    // The page went up instead of down: flip, come back, carry on.
                    driver.reverseScrollDirection()
                    try await driver.scroll(pixels: step)
                    continue
                }
            }

            switch result {
            case .noMovement:
                still += 1
                if still >= 2 { return finish(.bottom) }
            case .moved(let layout):
                still = 0
                recoveries = 0
                stitcher.add(frame, layout: layout)
                let middle = H - layout.header - layout.footer
                step = max(1, Int(Double(middle) * options.stepFraction))
            case .uncertain:
                // Still unsure: go back to where the last good frame was and try a smaller step.
                recoveries += 1
                if recoveries > 2 || step <= 8 { return finish(.lostTrack) }
                try await driver.scroll(pixels: -step)
                let back = try await settledFrame()
                if driver.isCancelled { return finish(.cancelled) }
                switch aligner.align(stitcher.last, back, expected: nil) {
                case .noMovement:
                    break
                case .moved(let layout):
                    // Landed a little below the last frame: that is a normal, confirmed step.
                    stitcher.add(back, layout: layout)
                default:
                    // Maybe a little above it; that is fine as long as it lines up the other way.
                    if case .moved = aligner.align(back, stitcher.last, expected: nil) { break }
                    return finish(.lostTrack)
                }
                step = max(1, step / 2)
            }
        }
    }

    /// Captures until two quick captures in a row are the same, so smooth scrolling and
    /// animations have finished. Gives up after `maxSettleTries` and uses the latest frame.
    func settledFrame() async throws -> PixelImage {
        var previous = try await capture()
        for _ in 0..<options.maxSettleTries {
            await driver.pause(milliseconds: options.settleIntervalMs)
            let current = try await capture()
            if aligner.isSame(previous, current) { return current }
            previous = current
        }
        return previous
    }

    func capture() async throws -> PixelImage {
        frames += 1
        return try await driver.captureFrame()
    }

    /// Scrolls up in big steps until nothing moves.
    func scrollToTop() async throws {
        var previous = try await settledFrame()
        let jump = -max(previous.height * 4, 2_000)
        var checked = false
        for _ in 0..<40 {
            if driver.isCancelled { return }
            // The first move is a small probe, so its direction can be checked by lining it up.
            try await driver.scroll(pixels: checked ? jump : -max(1, previous.height / 2))
            let current = try await settledFrame()
            if aligner.isSame(previous, current) { return }
            if !checked {
                checked = true
                // Content moved up, so the page went down: scrolling is flipped.
                if case .moved = aligner.align(previous, current) { driver.reverseScrollDirection() }
            }
            previous = current
        }
    }
}

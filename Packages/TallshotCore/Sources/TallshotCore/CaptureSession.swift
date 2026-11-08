/// What the capture loop needs from the outside world. The app implements it with
/// ScreenCaptureKit and scroll events; the tests implement it with generated pages.
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
    /// Switches to a way of scrolling. Returns false if this target can't scroll that way.
    func setScrollMethod(_ method: ScrollMethod) -> Bool
    /// Called with the view settled on new content (the first frame, then every step added),
    /// so the app can read the text that is on screen now.
    func contentSettled()
}

public extension CaptureDriver {
    func reverseScrollDirection() {}
    func setScrollMethod(_ method: ScrollMethod) -> Bool { method == .gesture }
    func contentSettled() {}
}

public struct CaptureOptions: Sendable, Equatable {
    /// Scroll step as a share of the moving area's height, once the fixed bands are known.
    public var stepFraction = 0.8
    /// The first step, before the header and footer are known.
    public var firstStepFraction = 0.5
    /// Browsers and Chromium apps: start at this share of the region and grow toward
    /// `stepFraction` only after a few steps moved what was asked. nil starts at full size.
    public var cautiousStartFraction: Double? = nil
    /// Stop at this many pixels tall.
    public var maxHeight = 30_000
    /// Stop at this many pixels in all (width × height), whatever the height limit. 50 million
    /// pixels is 200 MB of image; with the room the image grows into and the files made from it,
    /// a capture stays well under 1 GB of memory. On a 16-inch MacBook Pro's full screen width
    /// (3456 pixels) that is about 14,400 pixels tall; a narrower pane gets taller.
    public var maxPixels = 50_000_000
    /// Stop after this many seconds.
    public var maxSeconds = 60.0
    /// Time between the two quick captures that confirm the page has settled.
    public var settleIntervalMs = 50
    /// Give up waiting for the page to settle after this many tries (an animation that never stops).
    public var maxSettleTries = 8
    /// Scroll to the top first, then capture the whole thing.
    public var fromTop = false
    /// While scrolling to the top, wait up to this long for older content (a chat's earlier
    /// messages) to load before deciding the top has been reached.
    public var topLoadWaitMs = 1500
    /// The region is a fallback (a whole window or web page, not a real scroll area): crop the
    /// finished image to the columns that moved, so an app's sidebar is left out.
    public var cropToMovingColumns = false
    /// Keep the frames and a step log in memory so a diagnostic report can be saved if the
    /// capture stops early. Off unless the user turns the setting on.
    public var keepDiagnostics = false

    public init() {}
}

public enum StopReason: String, Sendable, Equatable, CaseIterable {
    /// Reached the bottom: a scroll moved nothing, twice in a row.
    case bottom
    case heightCap
    /// The image reached `maxPixels` (it is wide as well as tall).
    case sizeCap
    case timeCap
    case cancelled
    /// A step could not be lined up even after walking back; kept what was safe.
    case lostTrack
    /// The very first scroll moved nothing, with every way of scrolling: the pointer is probably
    /// not over the part that scrolls. One screen is kept.
    case didNotScroll

    /// Whether the capture ended before the page did.
    public var isEarly: Bool { self != .bottom }

    /// The pop-up's headline when it replaces the usual "Saved and copied." An early stop must
    /// never look like a normal capture.
    public var headline: String? {
        switch self {
        case .bottom: nil
        case .heightCap: "Stopped at the height limit"
        case .sizeCap: "Stopped at the size limit"
        case .timeCap: "Stopped at the time limit"
        case .cancelled: "Stopped early"
        case .lostTrack: "Capture stopped early"
        case .didNotScroll: "This area didn't scroll"
        }
    }

    /// The short note shown under the headline.
    public var note: String {
        switch self {
        case .bottom: ""
        case .heightCap: "The page goes on. Raise the height limit in Settings to get more."
        case .sizeCap: "The page goes on. This is the biggest image Tallshot makes at this width. Capture a narrower window or pane to get more."
        case .timeCap: "The page goes on. Raise the time limit in Settings to get more."
        case .cancelled: "You moved the mouse or pressed a key. Kept what was captured."
        case .lostTrack: "The page jumped or changed while scrolling and couldn't be lined up. Kept only the part that lined up."
        case .didNotScroll: "Kept one screen. Point at the part that scrolls and try again, or use Capture from Top if it's already at the end."
        }
    }
}

/// One line of the step log, for the diagnostic report.
public struct StepRecord: Sendable, Equatable {
    public var phase: String
    public var method: ScrollMethod
    /// Pixels the loop wanted to move, and what it asked the driver for after correcting for
    /// how far this app actually scrolls.
    public var wanted: Int
    public var sent: Int
    /// Pixels it really moved (nil when it couldn't be lined up).
    public var measured: Int?
    /// "moved", "no movement" or "uncertain"; with the line-up score.
    public var outcome: String
    public var score: Double
    public var header = 0, footer = 0, overlayBand = 0
    public var frame: Int
}

/// What a diagnostic report holds. Only built when `keepDiagnostics` is on.
public struct Diagnostics: Sendable {
    public var steps: [StepRecord]
    /// Frames with their number in capture order. The first few and the last ones are kept.
    public var frames: [(number: Int, image: PixelImage)]
    public var framesDropped: Int

    /// The report as plain text, one step per line.
    public func text(reason: StopReason, region: String, appName: String, result: CaptureResult) -> String {
        var lines = [
            "Tallshot diagnostic report",
            "App: \(appName)",
            "Region: \(region)",
            "Stopped: \(reason.rawValue)\(reason.headline.map { " (\($0))" } ?? "")",
            "Image: \(result.image.width) x \(result.image.height) px, \(result.steps) steps, \(result.frames) frames, \(String(format: "%.1f", result.seconds)) s",
            "Scroll method at the end: \(result.scrollMethod)",
            "Cropped to columns: \(result.croppedColumns.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "no")",
            "Frames saved: \(frames.count)\(framesDropped > 0 ? " (\(framesDropped) more were not kept, to save memory)" : "")",
            "",
            "phase | method | wanted px | sent px | measured px | outcome | score | header | footer | overlay band | frame",
        ]
        for s in steps {
            lines.append([s.phase, "\(s.method)", "\(s.wanted)", "\(s.sent)", s.measured.map(String.init) ?? "-", s.outcome,
                          String(format: "%.3f", s.score), "\(s.header)", "\(s.footer)", "\(s.overlayBand)", "\(s.frame)"]
                .joined(separator: " | "))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct CaptureResult: Sendable {
    public var image: PixelImage
    public var reason: StopReason
    public var steps: Int
    public var frames: Int
    public var seconds: Double
    /// Fixed rows at the top (from the first step) and at the bottom (from the last step,
    /// including any floating overlay band), so a checker can look only at the content.
    public var header = 0
    public var footer = 0
    /// The columns kept when the image was cropped to what moved (nil when not cropped).
    public var croppedColumns: Range<Int>?
    /// The way of scrolling in use at the end.
    public var scrollMethod: ScrollMethod = .gesture
    /// Times the page overshot (moved too far to line up) and was walked back.
    public var overshoots = 0
    /// Only when `keepDiagnostics` was on.
    public var diagnostics: Diagnostics?
}

/// Runs one scrolling capture from start to finish.
///
/// It never assumes a scroll moved what was asked. Every step is measured by lining the new
/// frame up with the last one, and the loop adapts:
/// - **Gain.** If the app moves further than asked (momentum, a different line size), later
///   requests are scaled down by how much further it went.
/// - **Step size.** Browsers start with small steps; steps grow only after a few of them moved
///   what was asked, and shrink after an overshoot.
/// - **Overshoot.** If a step went so far that nothing overlaps, the loop walks back in small
///   steps until the view overlaps the last good frame again, then carries on.
/// - **Method.** The first way of scrolling the app ignores, or that moves far from the request,
///   is swapped for the next one.
@MainActor
public final class CaptureSession {
    public let driver: CaptureDriver
    public let options: CaptureOptions
    public let aligner: FrameAligner
    public private(set) var frames = 0
    private var log: [StepRecord] = []
    private var kept: [(number: Int, image: PixelImage)] = []
    private var dropped = 0
    private var method = ScrollMethod.gesture
    /// Multiplier from "pixels wanted" to "pixels asked for". Lowered when the app overshoots.
    private var gain = 1.0
    private var lastRatio: Double?
    private var shortSteps = 0

    public init(driver: CaptureDriver, options: CaptureOptions = CaptureOptions(), aligner: FrameAligner = FrameAligner()) {
        self.driver = driver
        self.options = options
        self.aligner = aligner
    }

    // MARK: Scrolling with measurement

    /// Asks the driver to move `wanted` pixels, corrected by the gain. Returns what was sent.
    @discardableResult
    func scroll(wanted: Int) async throws -> Int {
        let sent = wanted == 0 ? 0 : (wanted > 0 ? 1 : -1) * max(1, Int((Double(abs(wanted)) * gain).rounded()))
        try await driver.scroll(pixels: sent)
        return sent
    }

    /// Learns from a measured move: if the app went much further than wanted (momentum, big
    /// lines), ask for proportionally less from now on. After several steps in a row that came
    /// up well short, ask for a bit more again (one short step proves nothing: the end of a
    /// page looks the same).
    func learn(wanted: Int, measured: Int) {
        guard wanted != 0, measured > 0 else { return }
        let q = Double(measured) / Double(abs(wanted))
        lastRatio = q
        if q > 1.3 {
            gain = max(0.03, gain / q)
            shortSteps = 0
        } else if q < 0.6 {
            shortSteps += 1
            if shortSteps >= 3 { gain = min(1, gain * 1.5); shortSteps = 0 }
        } else {
            shortSteps = 0
        }
    }

    func record(_ phase: String, wanted: Int, sent: Int, _ result: Alignment) {
        var rec = StepRecord(phase: phase, method: method, wanted: wanted, sent: sent, measured: nil, outcome: "uncertain", score: 0, frame: frames)
        switch result {
        case .noMovement: rec.outcome = "no movement"; rec.measured = 0; rec.score = 1
        case .moved(let l):
            rec.outcome = "moved"; rec.measured = l.offset; rec.score = l.score
            rec.header = l.header; rec.footer = l.footer; rec.overlayBand = l.overlayBand
        case .uncertain(let s): rec.score = s
        }
        log.append(rec)
    }

    func select(_ m: ScrollMethod) -> Bool {
        guard driver.setScrollMethod(m) else { return false }
        method = m
        return true
    }

    /// The next way of scrolling after `m` that this target supports.
    func selectNext(after m: ScrollMethod) -> Bool {
        var next = m.next
        while let n = next {
            if select(n) { return true }
            next = n.next
        }
        return false
    }

    /// How far a measured/requested ratio is from 1, either way (2 and 0.5 are both 2).
    func farness(_ r: Double) -> Double { r <= 0 ? 100 : max(r, 1 / r) }

    // MARK: The capture

    public func run() async throws -> CaptureResult {
        let start = driver.now
        // The first way of scrolling the target supports (exact scroll-bar positioning when the
        // accessibility tree offers it, else a trackpad gesture).
        method = ScrollMethod.allCases.first { driver.setScrollMethod($0) } ?? .gesture
        if options.fromTop { try await scrollToTop(start: start) }

        var first = try await settledFrame()
        driver.contentSettled()
        var stitcher = Stitcher(first: first)
        let H = first.height, W = first.width
        // The tallest the image may get: the height limit, or less for a wide image so its total
        // pixels stay within the budget. Never less than one screen.
        let byPixels = max(H, options.maxPixels / max(1, W))
        let heightLimit = min(options.maxHeight, byPixels)
        let limitReason: StopReason = byPixels < options.maxHeight ? .sizeCap : .heightCap
        let target = options.stepFraction
        var fraction = options.cautiousStartFraction.map { min($0, target) } ?? target
        var want = max(1, Int(Double(H) * min(options.firstStepFraction, fraction)))
        var middle = H
        var still = 0
        var failures = 0
        var overshoots = 0
        var goodSteps = 0
        var directionChecked = options.fromTop
        var rescrolledToTop = false
        var methodCompared = false
        var compareFrom: (method: ScrollMethod, ratio: Double)? = nil
        var flipTried = false, flippedForTry = false
        var firstHeader = 0, lastFooter = 0
        var movingColumns: Range<Int>? = nil

        /// Lines up two frames. If that fails but the columns known to scroll didn't change, only
        /// something beside them did (a chat list lighting up): that's standing still, not lost.
        func lineUp(_ a: PixelImage, _ b: PixelImage, expected: Int? = nil) -> Alignment {
            let result = aligner.align(a, b, expected: expected)
            if case .uncertain = result, let span = movingColumns, aligner.isSame(a.columns(span), b.columns(span)) {
                return .noMovement
            }
            return result
        }

        func finish(_ reason: StopReason) -> CaptureResult {
            var footer = lastFooter
            if stitcher.image.height > heightLimit { stitcher.cap(height: heightLimit); footer = 0 }
            var image = stitcher.image
            var cropped: Range<Int>? = nil
            if options.cropToMovingColumns, let span = movingColumns {
                let margin = max(8, W / 100)
                let keep = max(0, span.lowerBound - margin)..<min(W, span.upperBound + margin)
                if keep.count < W * 97 / 100 { image = image.columns(keep); cropped = keep }
            }
            var r = CaptureResult(image: image, reason: reason, steps: stitcher.steps, frames: frames, seconds: driver.now - start,
                                  header: firstHeader, footer: footer, croppedColumns: cropped, scrollMethod: method, overshoots: overshoots)
            if options.keepDiagnostics { r.diagnostics = Diagnostics(steps: log, frames: kept, framesDropped: dropped) }
            return r
        }

        func accept(_ frame: PixelImage, _ layout: PairLayout) {
            if stitcher.steps == 0 { firstHeader = layout.header }
            lastFooter = layout.footer
            if let cols = layout.movingColumns {
                movingColumns = movingColumns.map { min($0.lowerBound, cols.lowerBound)..<max($0.upperBound, cols.upperBound) } ?? cols
            }
            stitcher.add(frame, layout: layout)
            middle = H - layout.header - layout.footer
            driver.contentSettled()
        }

        /// After a step that couldn't be lined up (usually an overshoot: the page flew past),
        /// walks back in small steps until the view overlaps the last good frame again.
        /// Returns false if it never found it again.
        func walkBack(from lost: PixelImage) async throws -> Bool {
            var current = lost
            var back = max(8, middle / 4)
            var climbedFrom: [PixelImage] = []
            for _ in 0..<60 {
                if driver.isCancelled || driver.now - start >= options.maxSeconds { return false }
                switch lineUp(stitcher.last, current) {
                case .moved(let layout):
                    accept(current, layout)    // a little below the last frame: a normal step
                    return true
                case .noMovement:
                    return true                // back exactly where the last frame was
                case .uncertain:
                    break
                }
                let wanted: Int
                if case .moved(let above) = aligner.align(current, stitcher.last, expected: nil) {
                    // Above the last good frame: come most of the way down, gently.
                    wanted = max(1, above.offset * 3 / 4)
                } else {
                    // Back at a spot it already climbed from: more walking would only repeat.
                    if climbedFrom.contains(where: { aligner.isSame($0, current) }) { return false }
                    climbedFrom.append(current)
                    wanted = -back
                }
                let sent = try await scroll(wanted: wanted)
                let next = try await settledFrame()
                // Measure the walk itself, so a back step that also overshoots teaches the gain.
                let moved = aligner.align(current, next, expected: nil)
                let movedBack = aligner.align(next, current, expected: nil)
                if case .moved(let l) = moved { learn(wanted: wanted, measured: l.offset); back = max(8, middle / 2) }
                else if case .moved(let l) = movedBack { learn(wanted: wanted, measured: l.offset); back = max(8, middle / 2) }
                record("walk back", wanted: wanted, sent: sent, moved)
                current = next
            }
            return false
        }

        while true {
            if driver.isCancelled { return finish(.cancelled) }
            if stitcher.image.height >= heightLimit { return finish(limitReason) }
            if driver.now - start >= options.maxSeconds { return finish(.timeCap) }

            let sent = try await scroll(wanted: want)
            var frame = try await settledFrame()
            if driver.isCancelled { return finish(.cancelled) }

            var result = lineUp(stitcher.last, frame, expected: want)
            var wait = options.settleIntervalMs * 3
            for _ in 0..<3 {
                guard case .uncertain = result else { break }
                // Content may still have been moving, or a popup was passing: wait, look again.
                await driver.pause(milliseconds: wait)
                wait *= 2
                frame = try await settledFrame()
                if driver.isCancelled { return finish(.cancelled) }
                result = lineUp(stitcher.last, frame, expected: want)
            }
            record("step", wanted: want, sent: sent, result)

            if !directionChecked {
                directionChecked = true
                if result == .noMovement || { if case .uncertain = result { return true } else { return false } }(),
                   case .moved = aligner.align(frame, stitcher.last, expected: want) {
                    // The page went up instead of down: flip, come back, carry on.
                    driver.reverseScrollDirection()
                    flippedForTry = false
                    try await driver.scroll(pixels: sent)
                    _ = try await settledFrame()
                    continue
                }
            }

            if stitcher.steps == 0 && result == .noMovement {
                // The very first scroll moved nothing. Never report that as the bottom. At the
                // top of a page, a reversed scroll direction looks just like this: try the other
                // direction once. (At the real bottom that scroll goes up, and the direction check
                // above flips back and scrolls back.) Then the next way of scrolling; if nothing
                // works, say so.
                if !flipTried && !options.fromTop {
                    flipTried = true
                    flippedForTry = true
                    driver.reverseScrollDirection()
                    directionChecked = false
                    continue
                }
                if flippedForTry {
                    // That moved nothing either: the app ignores this way of scrolling. Put the
                    // direction back before trying the next one.
                    flippedForTry = false
                    driver.reverseScrollDirection()
                }
                if selectNext(after: method) {
                    directionChecked = false
                    continue
                }
                return finish(.didNotScroll)
            }

            switch result {
            case .noMovement:
                still += 1
                if still >= 2 { return finish(.bottom) }
            case .moved(let layout):
                if stitcher.steps == 0 && method != .gesture && method != .scrollBar && options.fromTop && !rescrolledToTop {
                    // The way to the top used a way of scrolling this app ignores: go again.
                    rescrolledToTop = true
                    try await scrollToTop(start: start)
                    first = try await settledFrame()
                    stitcher = Stitcher(first: first)
                    continue
                }
                still = 0
                failures = 0
                learn(wanted: want, measured: layout.offset)
                let ratio = Double(layout.offset) / Double(max(1, want))
                // How far this way of scrolling goes per pixel actually sent, before any correction,
                // so two ways are compared fairly.
                let raw = Double(layout.offset) / Double(max(1, sent))
                accept(frame, layout)

                // Try another way of scrolling once if this one lands far from the request, and
                // keep whichever lands closer.
                if !methodCompared {
                    if let c = compareFrom {
                        methodCompared = true
                        if farness(c.ratio) <= farness(raw) { _ = select(c.method) }   // a tie keeps the first
                    } else if ratio > 1.6, method == .gesture || method == .wheelPixels {
                        let other: ScrollMethod = method == .gesture ? .wheelPixels : .gesture
                        if driver.setScrollMethod(other) { compareFrom = (method, raw); method = other } else { methodCompared = true }
                    }
                }

                // Grow the step only after a few steps moved about what was asked.
                if ratio >= 0.6 && ratio <= 1.5 { goodSteps += 1 } else { goodSteps = 0 }
                if goodSteps >= 3 && fraction < target { fraction = min(target, fraction + 0.15); goodSteps = 0 }
                want = max(1, Int(Double(middle) * fraction))
            case .uncertain:
                // Usually an overshoot: the page moved so far that nothing overlaps. Ask for
                // less from now on, walk back until it overlaps again, and carry on smaller.
                overshoots += 1
                failures += 1
                gain = max(0.03, gain * 0.5)
                fraction = max(0.15, fraction * 0.6)
                goodSteps = 0
                if !methodCompared, compareFrom == nil, method == .gesture || method == .wheelPixels {
                    let other: ScrollMethod = method == .gesture ? .wheelPixels : .gesture
                    if driver.setScrollMethod(other) { compareFrom = (method, 99); method = other }
                }
                if failures > 4 { return finish(.lostTrack) }
                if !(try await walkBack(from: frame)) {
                    return driver.isCancelled ? finish(.cancelled) : (driver.now - start >= options.maxSeconds ? finish(.timeCap) : finish(.lostTrack))
                }
                want = max(1, Int(Double(middle) * fraction))
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
            if aligner.isSame(previous, current) { keep(current); return current }
            previous = current
        }
        keep(previous)
        return previous
    }

    func capture() async throws -> PixelImage {
        frames += 1
        return try await driver.captureFrame()
    }

    /// Diagnostics: keep the first 8 settled frames and the latest 24, never more.
    private func keep(_ frame: PixelImage) {
        guard options.keepDiagnostics else { return }
        kept.append((frames, frame))
        if kept.count > 32 { kept.remove(at: 8); dropped += 1 }
    }

    /// Scrolls up in big steps until two scrolls in a row move nothing. Chats load older
    /// messages when you reach the top, so after a scroll that moved nothing it waits longer
    /// (up to `topLoadWaitMs`) and tries again; new content resets the count.
    func scrollToTop(start: Double) async throws {
        var previous = try await settledFrame()
        let jump = -max(previous.height * 4, 2_000)
        var checked = false
        var still = 0
        var wait = 0
        for _ in 0..<400 {
            if driver.isCancelled || driver.now - start >= options.maxSeconds { return }
            // The first move is a small probe, so its direction can be checked by lining it up.
            // After a scroll that moved nothing, give older content time to load first.
            if wait > 0 { await driver.pause(milliseconds: wait) }
            let wanted = checked ? jump : -max(1, previous.height / 2)
            try await driver.scroll(pixels: wanted)
            let current = try await settledFrame()
            if aligner.isSame(previous, current) {
                log.append(StepRecord(phase: "to top", method: method, wanted: wanted, sent: wanted, measured: 0, outcome: "no movement", score: 1, frame: frames))
                still += 1
                if still >= 2 { return }
                // Maybe at the top, maybe older content is loading: give it time, then look again.
                wait = options.topLoadWaitMs
                continue
            }
            log.append(StepRecord(phase: "to top", method: method, wanted: wanted, sent: wanted, measured: nil, outcome: "changed", score: 0, frame: frames))
            still = 0
            wait = 0
            if !checked {
                checked = true
                // Content moved up, so the page went down: scrolling is flipped.
                if case .moved = aligner.align(previous, current) { driver.reverseScrollDirection() }
            }
            previous = current
        }
    }
}

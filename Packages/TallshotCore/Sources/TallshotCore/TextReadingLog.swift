/// Keeps track of whether the text read from an app during a scrolling capture is complete.
/// Each step's reading of the accessibility tree has a time and size limit; a reading that hits
/// it skips the rest of the tree without saying so. This log records those readings, and the
/// one longer reading taken at the end (at the same place as the last step's reading, so a
/// complete final reading covers a cut-short last one).
public struct TextReadingLog: Equatable, Sendable {
    public init() {}

    /// Readings taken at scroll steps, and how many of them hit their limit.
    public private(set) var readings = 0
    public private(set) var cutShort = 0
    private var lastWasCutShort = false
    /// The final reading: nil until it is taken, then whether it hit its limit.
    private var finalCutShort: Bool?

    /// A reading taken at a scroll step.
    public mutating func reading(cutShort short: Bool) {
        readings += 1
        if short { cutShort += 1 }
        lastWasCutShort = short
    }

    /// The longer reading taken once the capture has finished.
    public mutating func finalReading(cutShort short: Bool) { finalCutShort = short }

    /// True when some text may be missing from the export.
    public var mayBeMissingText: Bool {
        guard let finalCutShort else { return cutShort > 0 }
        let uncovered = cutShort - (lastWasCutShort ? 1 : 0)
        return finalCutShort || uncovered > 0
    }

    /// What the pop-up and the first line of the Markdown file say; nil when nothing is missing.
    public var note: String? {
        guard mayBeMissingText else { return nil }
        let counted = readings > 0 ? " (\(cutShort) of \(readings) readings ran out of time)" : ""
        return "Some text may be missing: the app was too slow to share all of it while the page scrolled\(counted). The image is complete."
    }
}

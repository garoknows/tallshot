/// Builds the tall image one confirmed step at a time.
///
/// The tall image always ends with the full bottom of the latest frame. On each step it first
/// takes off the latest frame's fixed footer, adds only the newly revealed strip of content,
/// then puts the new frame's footer back. So a header appears once at the top (from the first
/// frame), a footer once at the bottom (from the last frame), and content exactly once.
public struct Stitcher: Sendable {
    public private(set) var image: PixelImage
    public private(set) var last: PixelImage
    public private(set) var steps = 0

    public init(first: PixelImage) {
        image = first
        last = first
    }

    /// Adds `frame`, which `FrameAligner` confirmed against the previous frame with `layout`.
    public mutating func add(_ frame: PixelImage, layout: PairLayout) {
        precondition(frame.width == last.width && frame.height == last.height, "frames must be the same size")
        let H = frame.height
        let middleEnd = H - layout.footer
        precondition(layout.offset > 0 && layout.offset <= middleEnd - layout.header, "offset out of range")

        image.dropLastRows(layout.footer)
        image.reserveRows(layout.offset + layout.footer)
        let paint = layout.sidebars.map { ($0.columns, $0.fill) }
        image.appendRows(of: frame, (middleEnd - layout.offset)..<middleEnd, paint: paint)
        image.appendRows(of: frame, middleEnd..<H)
        last = frame
        steps += 1
    }

    /// Cuts the tall image to at most `height` rows (the height cap).
    public mutating func cap(height: Int) {
        image.truncate(toHeight: height)
    }
}

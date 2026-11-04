import AppKit
import SwiftUI

/// Tallshot's brand colors and drawings.
enum Brand {
    static let night = Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255)
    static let lift = Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0xFF / 255)
    static let ruler = Color(red: 0xFF / 255, green: 0xC8 / 255, blue: 0x3D / 255)
    static let paper = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xEF / 255)
    static let liftNS = NSColor(srgbRed: 0x2F / 255, green: 0x6B / 255, blue: 0xFF / 255, alpha: 1)

    static func wordmark(_ size: CGFloat) -> some View {
        Text("tallshot").font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(night)
    }
}

/// The one drawing behind the menu bar icon, the app icon, the site icon and the docs: a tall,
/// narrow rounded rectangle with a small down chevron at the bottom, in an 18-point square.
/// tools/DocRenderer writes the same numbers into the SVG files.
enum TallGlyph {
    static let body = CGRect(x: 5.25, y: 1.25, width: 7.5, height: 15.5)
    static let corner: CGFloat = 2.2
    static let line: CGFloat = 1.5
    static let chevron = [CGPoint(x: 7, y: 11), CGPoint(x: 9, y: 13), CGPoint(x: 11, y: 11)]
    /// Height of the drawing, outer edge of the line to outer edge of the line.
    static let outerHeight = body.height + line

    /// The same drawing placed by hand on whole pixels for the two smallest icon sizes, where
    /// scaling it down blurs the chevron into a bar. In pixels of a square that many pixels wide.
    struct Snapped { var body: CGRect, corner: CGFloat, line: CGFloat, chevron: [CGPoint] }
    static func snapped(pixels: Int) -> Snapped? {
        switch pixels {
        case 16: Snapped(body: CGRect(x: 5.5, y: 3.5, width: 5, height: 9), corner: 1.4, line: 1,
                         chevron: [CGPoint(x: 6.5, y: 8.5), CGPoint(x: 8, y: 10), CGPoint(x: 9.5, y: 8.5)])
        case 32: Snapped(body: CGRect(x: 12, y: 8, width: 8, height: 16), corner: 2.4, line: 2,
                         chevron: [CGPoint(x: 13.5, y: 17), CGPoint(x: 16, y: 19.5), CGPoint(x: 18.5, y: 17)])
        default: nil
        }
    }
}

/// The menu bar icon, drawn as a template image so it matches light and dark menu bars. Filled
/// while capturing.
enum MenuBarIcon {
    static func image(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let body = NSBezierPath(roundedRect: TallGlyph.body, xRadius: TallGlyph.corner, yRadius: TallGlyph.corner)
            body.lineWidth = TallGlyph.line
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if filled { body.fill() } else { body.stroke() }
            let chevron = NSBezierPath()
            chevron.move(to: TallGlyph.chevron[0]); chevron.line(to: TallGlyph.chevron[1]); chevron.line(to: TallGlyph.chevron[2])
            chevron.lineWidth = TallGlyph.line
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            if filled {
                NSGraphicsContext.current?.compositingOperation = .clear
                chevron.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                chevron.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The app icon: the menu bar drawing in white on a Night rounded square, on Apple's macOS icon
/// grid (an 824 square with a corner of about 185, centered in 1024).
struct AppIconView: View {
    /// Share of the square's height the drawing fills.
    static let glyphShare: CGFloat = 0.72
    static let squareShare: CGFloat = 824.0 / 1024
    static let cornerShare: CGFloat = 185.0 / 824

    var size: CGFloat
    /// Apple's standard soft shadow, for the plain .icns only.
    var shadow = false
    /// How many pixels wide this will be drawn, for the plain .icns: 16 and 32 get snapped drawings.
    var pixels: Int? = nil

    var body: some View {
        let square = size * Self.squareShare
        let u = square * Self.glyphShare / TallGlyph.outerHeight
        let line = max(TallGlyph.line * u, 1)
        ZStack {
            RoundedRectangle(cornerRadius: square * Self.cornerShare, style: .continuous)
                .fill(Brand.night)
                .frame(width: square, height: square)
                .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 14 * size / 1024, y: 12 * size / 1024)
            Canvas { ctx, canvas in
                let rect: CGRect, corner: CGFloat, width: CGFloat, points: [CGPoint]
                if let px = pixels, let s = TallGlyph.snapped(pixels: px) {
                    let k = canvas.width / CGFloat(px)
                    rect = CGRect(x: s.body.minX * k, y: s.body.minY * k, width: s.body.width * k, height: s.body.height * k)
                    corner = s.corner * k
                    width = s.line * k
                    points = s.chevron.map { CGPoint(x: $0.x * k, y: $0.y * k) }
                } else {
                    func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: canvas.width / 2 + (pt.x - 9) * u, y: canvas.height / 2 + (pt.y - 9) * u) }
                    let b = TallGlyph.body
                    rect = CGRect(origin: p(b.origin), size: CGSize(width: b.width * u, height: b.height * u))
                    corner = TallGlyph.corner * u
                    width = line
                    points = TallGlyph.chevron.map(p)
                }
                ctx.stroke(Path(roundedRect: rect, cornerRadius: corner), with: .color(.white), lineWidth: width)
                var chev = Path()
                chev.addLines(points)
                ctx.stroke(chev, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

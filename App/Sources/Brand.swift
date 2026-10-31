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

/// The menu bar icon: a tall, narrow rounded rectangle with a small down chevron at the bottom,
/// drawn as a template image so it matches light and dark menu bars. Filled while capturing.
enum MenuBarIcon {
    static func image(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 5.25, y: 1.25, width: 7.5, height: 15.5), xRadius: 2.2, yRadius: 2.2)
            body.lineWidth = 1.5
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if filled { body.fill() } else { body.stroke() }
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 7, y: 11)); chevron.line(to: NSPoint(x: 9, y: 13)); chevron.line(to: NSPoint(x: 11, y: 11))
            chevron.lineWidth = 1.5
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

/// The app icon: a tall paper sheet rising out of a short screen frame, with ruler tick marks
/// down one edge.
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        let u = size / 64
        ZStack {
            RoundedRectangle(cornerRadius: 14 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.985, blue: 0.97), Brand.paper], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14 * u, style: .continuous).strokeBorder(Brand.night.opacity(0.08), lineWidth: 0.6 * u))
                .frame(width: 56 * u, height: 56 * u)
                .shadow(color: .black.opacity(0.18), radius: 1.4 * u, y: 0.7 * u)
            Canvas { ctx, _ in
                func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
                // Paper sheet.
                let sheet = Path(roundedRect: r(21, 8, 22, 40), cornerRadius: 2.5 * u)
                ctx.fill(sheet, with: .color(.white))
                ctx.stroke(sheet, with: .color(Brand.night), lineWidth: 2.3 * u)
                // Ruler ticks.
                for (i, y) in [13.0, 18, 23, 28, 33].enumerated() {
                    var p = Path(); p.move(to: CGPoint(x: 24.5 * u, y: y * u)); p.addLine(to: CGPoint(x: (i % 2 == 0 ? 28.5 : 26.5) * u, y: y * u))
                    ctx.stroke(p, with: .color(Brand.ruler), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
                }
                // Text lines.
                for (y, w) in [(14.0, 8.0), (20, 6), (26, 8)] {
                    var p = Path(); p.move(to: CGPoint(x: 31.5 * u, y: y * u)); p.addLine(to: CGPoint(x: (31.5 + w) * u, y: y * u))
                    ctx.stroke(p, with: .color(Brand.night.opacity(0.22)), style: StrokeStyle(lineWidth: 2 * u, lineCap: .round))
                }
                // Screen frame, open at the top where the sheet rises out.
                ctx.fill(Path(r(21, 35, 22, 12.5)), with: .color(Brand.lift.opacity(0.14)))
                var frame = Path()
                frame.move(to: CGPoint(x: 21 * u, y: 35 * u)); frame.addLine(to: CGPoint(x: 10 * u, y: 35 * u))
                frame.addLine(to: CGPoint(x: 10 * u, y: 50 * u))
                frame.addQuadCurve(to: CGPoint(x: 14 * u, y: 54 * u), control: CGPoint(x: 10 * u, y: 54 * u))
                frame.addLine(to: CGPoint(x: 50 * u, y: 54 * u))
                frame.addQuadCurve(to: CGPoint(x: 54 * u, y: 50 * u), control: CGPoint(x: 54 * u, y: 54 * u))
                frame.addLine(to: CGPoint(x: 54 * u, y: 35 * u)); frame.addLine(to: CGPoint(x: 43 * u, y: 35 * u))
                ctx.stroke(frame, with: .color(Brand.night), style: StrokeStyle(lineWidth: 3.2 * u, lineCap: .round, lineJoin: .round))
                var chev = Path()
                chev.move(to: CGPoint(x: 28 * u, y: 41 * u)); chev.addLine(to: CGPoint(x: 32 * u, y: 45 * u)); chev.addLine(to: CGPoint(x: 36 * u, y: 41 * u))
                ctx.stroke(chev, with: .color(Brand.lift), style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

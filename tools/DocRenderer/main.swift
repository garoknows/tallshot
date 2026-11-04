// Renders the app icon and the documentation pictures from the app's real SwiftUI views.
// Built by tools/render-assets.sh together with App/Sources (minus the app entry point).
// This tool is never shipped; the app itself writes only the PNGs the user asks for.
import AppKit
import SwiftUI
import TallshotCore

@MainActor
func png(_ view: some View, scale: CGFloat = 2, to url: URL) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let cg = r.cgImage else { print("render failed: \(url.lastPathComponent)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) \(cg.width)x\(cg.height)")
}

/// The drawing as SVG, from the same numbers as the app: the site icon, and the white layer of
/// the Icon Composer file (whose square fills the whole 1024 canvas before macOS insets it).
func glyphSVG(scale u: CGFloat, center: CGFloat) -> String {
    let b = TallGlyph.body, c = TallGlyph.chevron
    let n = { (v: CGFloat) in String(format: "%.3f", v) }
    let points = c.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " ")
    return """
    <g transform="translate(\(n(center)) \(n(center))) scale(\(n(u))) translate(-9 -9)" fill="none" stroke="#FFFFFF" stroke-width="\(n(TallGlyph.line))" stroke-linecap="round" stroke-linejoin="round">
        <rect x="\(n(b.minX))" y="\(n(b.minY))" width="\(n(b.width))" height="\(n(b.height))" rx="\(n(TallGlyph.corner))"/>
        <polyline points="\(points)"/>
      </g>
    """
}

func writeIconSVGs(root: URL) {
    let square: CGFloat = 824
    let u = square * AppIconView.glyphShare / TallGlyph.outerHeight
    let site = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 824 824">
      <rect width="824" height="824" rx="\(Int(AppIconView.cornerShare * square))" fill="#15171C"/>
      \(glyphSVG(scale: u, center: 412))
    </svg>

    """
    let layer = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
      \(glyphSVG(scale: 1024 * AppIconView.glyphShare / TallGlyph.outerHeight, center: 512))
    </svg>

    """
    try! site.write(to: root.appendingPathComponent("site/icon.svg"), atomically: false, encoding: .utf8)
    try! layer.write(to: root.appendingPathComponent("App/Resources/AppIcon.icon/Assets/glyph.svg"), atomically: false, encoding: .utf8)
}

/// A light, branded backdrop for documentation pictures.
struct Backdrop<Content: View>: View {
    var content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.12)))
            .padding(24)
            .background(Brand.paper)
            .environment(\.colorScheme, .light)
    }
}

/// A drawing of the open menu, matching MenuContent.
struct MenuPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Image(nsImage: MenuBarIcon.image(filled: false)).renderingMode(.template)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.1)))
                Text("Fri 9:41").font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                row("Capture Now", "⌃⌥⇧⌘T")
                row("Capture from Top", nil)
                Divider().padding(.vertical, 3)
                row("Settings…", "⌘,")
                row("Run Self-Test", nil)
                Divider().padding(.vertical, 3)
                row("Quit Tallshot", "⌘Q")
            }
            .padding(6)
            .frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)).shadow(radius: 6, y: 2))
            .padding(.leading, 112).padding(.top, 2).padding(.bottom, 12)
        }
        .frame(width: 420)
        .background(LinearGradient(colors: [Color(red: 0.86, green: 0.88, blue: 0.93), Brand.paper], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .light)
    }

    func row(_ title: String, _ key: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let key { Text(key).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

/// A drawn tall page for the pop-up thumbnail (never a real screenshot).
@MainActor
func sampleThumbnail() -> NSImage {
    let page = VStack(alignment: .leading, spacing: 5) {
        RoundedRectangle(cornerRadius: 1).fill(Brand.night).frame(width: 50, height: 6)
        ForEach(0..<14, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(i % 5 == 0 ? 0.6 : 0.3))
                .frame(width: CGFloat([70, 62, 74, 48, 66][i % 5]), height: 3)
        }
    }
    .padding(7).frame(width: 88, height: 128, alignment: .topLeading).background(Color.white)
    let r = ImageRenderer(content: page)
    r.scale = 2
    return NSImage(cgImage: r.cgImage!, size: NSSize(width: 88, height: 128))
}

@main
struct DocRenderer {
    @MainActor static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: DocRenderer <iconset dir> <docs images dir>"); exit(2) }
        let iconset = URL(fileURLWithPath: args[1])
        let docs = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        for base in [16, 32, 128, 256, 512] {
            png(AppIconView(size: CGFloat(base), shadow: true, pixels: base), scale: 1, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            png(AppIconView(size: CGFloat(base), shadow: true, pixels: base * 2), scale: 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        png(AppIconView(size: 256), scale: 2, to: docs.appendingPathComponent("icon.png"))
        writeIconSVGs(root: docs.deletingLastPathComponent().deletingLastPathComponent())
        png(Backdrop { SetupView(preview: (false, false)).environment(\.drawnButtons, true) }, to: docs.appendingPathComponent("setup-window.png"))
        png(Backdrop { SetupView(preview: (false, false), previewStep: .switchedOnNeedsReopen).environment(\.drawnButtons, true) }, to: docs.appendingPathComponent("setup-reopen.png"))
        png(Backdrop { AnnotatedSettings(pane: .screenRecording).padding(16) }, scale: 3, to: docs.appendingPathComponent("step1-screen-recording.png"))
        png(Backdrop { AnnotatedSettings(pane: .accessibility).padding(16) }, scale: 3, to: docs.appendingPathComponent("step2-accessibility.png"))
        png(MenuPicture(), to: docs.appendingPathComponent("menu.png"))
        png(ToastView(message: "Saved and copied.", detail: nil, thumbnail: sampleThumbnail(), heightBadge: "8,412 px", onClick: {})
                .padding(24).background(Brand.paper).environment(\.colorScheme, .light),
            to: docs.appendingPathComponent("toast.png"))
        png(ToastView(message: "Saved and copied.", detail: "Also saved PDF, Word and Markdown.\nText from the app's accessibility tree (exact text).",
                      thumbnail: sampleThumbnail(), heightBadge: "8,412 px", onClick: {})
                .padding(24).background(Brand.paper).environment(\.colorScheme, .light),
            to: docs.appendingPathComponent("popup-exports.png"))
    }
}

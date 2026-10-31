import AppKit
import SwiftUI

/// A borderless, click-through window floating above everything. It is excluded from screen
/// capture (`sharingType = .none`), and Tallshot captures only the target window anyway, so
/// the flash and the toast never appear in an image.
@MainActor
func overlayWindow(frame: NSRect, clickThrough: Bool) -> NSPanel {
    let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.level = .statusBar
    w.ignoresMouseEvents = clickThrough
    w.sharingType = .none
    w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    w.isReleasedWhenClosed = false
    return w
}

/// A 2-point outline in the accent color around the picked area for about 300 ms, fading out.
@MainActor
enum RegionFlash {
    private static var current: NSPanel?

    static func show(_ region: CGRect) {
        current?.orderOut(nil)
        let frame = TargetFinder.toAppKit(region).insetBy(dx: -3, dy: -3)
        let w = overlayWindow(frame: frame, clickThrough: true)
        w.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.lift, lineWidth: 2).padding(1)
                .frame(width: frame.width, height: frame.height))
        w.alphaValue = 1
        w.orderFrontRegardless()
        current = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { w.orderOut(nil); if current === w { current = nil } } })
        }
    }
}

/// The small corner toast: thumbnail, a short message and the height badge. Click to show the
/// file in Finder. Fades after 3 seconds.
@MainActor
enum Toast {
    private static var current: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(message: String, detail: String? = nil, thumbnail: NSImage? = nil, heightBadge: String? = nil, file: URL? = nil, near region: CGRect? = nil) {
        current?.orderOut(nil)
        hideWork?.cancel()
        let view = ToastView(message: message, detail: detail, thumbnail: thumbnail, heightBadge: heightBadge) {
            if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            hide()
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let screen = region.flatMap { r in NSScreen.screens.first { $0.frame.contains(TargetFinder.toAppKit(r).center) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 18, y: vf.minY + 18, width: size.width, height: size.height)
        let w = overlayWindow(frame: frame, clickThrough: false)
        w.contentView = hosting
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
        current = w
        let work = DispatchWorkItem { MainActor.assumeIsolated { hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    static func hide() {
        guard let w = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { w.orderOut(nil) } })
    }
}

extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

struct ToastView: View {
    var message: String
    var detail: String?
    var thumbnail: NSImage?
    var heightBadge: String?
    var onClick: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 64, alignment: .top).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.system(size: 13, weight: .semibold, design: .rounded))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let heightBadge {
                    Text(heightBadge).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Brand.night)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Brand.ruler))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}

import AppKit
import Combine
import SwiftUI

/// Watches the two permissions once a second while the setup window is open.
@MainActor
final class PermissionWatcher: ObservableObject {
    @Published var screen = Permissions.screenRecording
    @Published var accessibility = Permissions.accessibility
    private var timer: AnyCancellable?

    func start() {
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screen = Permissions.screenRecording
                self?.accessibility = Permissions.accessibility
            }
        }
    }
    func stop() { timer = nil }
}

/// True when a view is being drawn for the docs: ImageRenderer can't draw real AppKit
/// buttons, so buttons are drawn as look-alikes instead.
private struct DrawnButtonsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var drawnButtons: Bool {
        get { self[DrawnButtonsKey.self] }
        set { self[DrawnButtonsKey.self] = newValue }
    }
}

/// A normal button, or a drawn look-alike when rendering pictures for the docs.
struct SetupButton: View {
    var title: String
    var prominent = false
    var action: () -> Void
    @Environment(\.drawnButtons) private var drawn
    var body: some View {
        if drawn {
            Text(title).font(.system(size: 13))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? Brand.lift : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(prominent ? 0 : 0.15)))
                .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
        } else if prominent {
            Button(title, action: action).keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action)
        }
    }
}

/// One window that walks through the two permissions with annotated pictures. Each step turns
/// green by itself once granted. A "Run self-test" button waits at the end.
struct SetupView: View {
    @StateObject private var watch = PermissionWatcher()
    var preview: (screen: Bool, accessibility: Bool)? = nil

    var screen: Bool { preview?.screen ?? watch.screen }
    var ax: Bool { preview?.accessibility ?? watch.accessibility }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Brand.wordmark(24)
                    Text("Two permissions, then one hotkey does the rest.").foregroundStyle(.secondary)
                }
            }
            SetupStep(number: 1, title: "Allow Screen Recording",
                      detail: "Lets Tallshot take pictures of the window you point at, only while a capture runs. Nothing leaves your Mac.",
                      granted: screen, button: "Open Screen Recording",
                      action: {
                          Permissions.requestScreenRecording()
                          Permissions.openSettings("Privacy_ScreenCapture")
                      },
                      picture: AnnotatedSettings(pane: .screenRecording))
            SetupStep(number: 2, title: "Allow Accessibility",
                      detail: "Lets Tallshot find the scrolling area under the pointer and scroll it, the way a trackpad does.",
                      granted: ax, button: "Open Accessibility",
                      action: {
                          Permissions.requestAccessibility()
                          Permissions.openSettings("Privacy_Accessibility")
                      },
                      picture: AnnotatedSettings(pane: .accessibility))
            HStack(alignment: .center) {
                Text(screen && ax
                     ? "All set. Point at any pane and press \(Settings.shared.captureHotkey?.display ?? "the hotkey"). Only that pane is captured. Settings → Output can also save a PDF, Word file or Markdown."
                     : "This window updates by itself. If a switch is on but the step stays grey, quit and reopen Tallshot (macOS asks for that after Screen Recording).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                SetupButton(title: "Run Self-Test") {
                    Settings.shared.setupShown = true
                    WindowRouter.shared.close("setup")
                    SelfTest.shared.run()
                }
                .disabled(!(screen && ax))
                SetupButton(title: screen && ax ? "Done" : "Later", prominent: true) {
                    Settings.shared.setupShown = true
                    WindowRouter.shared.close("setup")
                }
            }
        }
        .padding(24)
        .frame(width: 660)
        .onAppear { watch.start() }
        .onDisappear { watch.stop() }
    }
}

struct SetupStep<Picture: View>: View {
    var number: Int
    var title: String
    var detail: String
    var granted: Bool
    var button: String
    var action: () -> Void
    var picture: Picture

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(granted ? Color.green : Brand.lift).frame(width: 24, height: 24)
                        if granted {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        }
                    }
                    Text(title).font(.headline)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    SetupButton(title: button, action: action)
                }
            }
            .frame(width: 240, alignment: .leading)
            picture.opacity(granted ? 0.45 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(granted ? Color.green.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(granted ? Color.green.opacity(0.5) : Color.clear))
    }
}

/// A drawn picture of the System Settings privacy pane, with red boxes and numbered markers on
/// exactly where to click: (1) Privacy & Security, (2) the pane, (3) Tallshot's switch.
/// Drawn, not screenshotted, so it follows light and dark mode and contains nothing personal.
struct AnnotatedSettings: View {
    enum Pane { case screenRecording, accessibility }
    var pane: Pane
    private let red = Color(red: 0.89, green: 0.16, blue: 0.16)

    var paneTitle: String { pane == .screenRecording ? "Screen & System Audio Recording" : "Accessibility" }
    var paneNote: String {
        pane == .screenRecording ? "Allow the apps below to record the content of your screen and audio."
                                 : "Allow the apps below to control your computer."
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6) } }
                        .padding(.bottom, 4)
                    sidebarRow("General", symbol: "gearshape")
                    sidebarRow("Displays", symbol: "display")
                    sidebarRow("Privacy & Security", symbol: "hand.raised.fill", selected: true)
                        .overlay(markerBox(1))
                    sidebarRow("Desktop & Dock", symbol: "dock.rectangle")
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 128)
                .background(Color.secondary.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 8))
                        Text(paneTitle).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .overlay(markerBox(2))
                    Text(paneNote).font(.system(size: 7.5)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        appRow("Another App", on: true)
                        Divider()
                        appRow("Tallshot", on: false, isTallshot: true)
                            .overlay(alignment: .trailing) { markerBox(3).frame(width: 34, height: 20).offset(x: 4) }
                    }
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.07)))
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
        }
        .frame(width: 340, height: 150)
        .accessibilityLabel("System Settings, Privacy & Security, \(paneTitle): turn on the switch next to Tallshot.")
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7)).frame(width: 10)
            Text(title).font(.system(size: 8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func appRow(_ name: String, on: Bool, isTallshot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if isTallshot {
                AppIconView(size: 14)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 12, height: 12)
            }
            Text(name).font(.system(size: 8.5))
            Spacer()
            Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 18, height: 10)
                .overlay(Circle().fill(.white).frame(width: 8, height: 8).offset(x: on ? 4 : -4))
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func markerBox(_ n: Int) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(red, lineWidth: 1.8)
            .padding(-2)
            .overlay(alignment: .topTrailing) {
                Text("\(n)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(red))
                    .offset(x: 8, y: -8)
            }
    }
}

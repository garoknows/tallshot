import AppKit
import Carbon.HIToolbox
import TallshotCore

/// A key plus modifiers, stored as Carbon codes (what RegisterEventHotKey wants).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey, optionKey, controlKey, shiftKey

    static let defaultCapture = Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))

    /// "⌃⌥⇧⌘T"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
                                    kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
                                    kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let n = names[Int(code)] { return n }
        let letters: [Int: String] = [kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M",
            kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9"]
        return letters[Int(code)] ?? "Key \(code)"
    }

    /// Converts an AppKit key event into a Carbon hotkey. Needs at least one of ⌘ ⌃ ⌥.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

/// How carefully to scroll: a trade between speed and robustness on slow pages.
enum ScrollSpeed: String, CaseIterable, Identifiable {
    case careful, normal, fast
    var id: String { rawValue }
    var title: String { ["careful": "Careful", "normal": "Normal", "fast": "Fast"][rawValue]! }
    var stepFraction: Double { switch self { case .careful: 0.6; case .normal: 0.8; case .fast: 0.85 } }
    var settleMs: Int { switch self { case .careful: 90; case .normal: 50; case .fast: 30 } }
}

/// Every setting Tallshot stores. They live in the app's own preferences (UserDefaults) and
/// nothing else is ever stored.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum Keys {
        static let captureHotkey = "captureHotkey", fromTopHotkey = "fromTopHotkey", saveFolder = "saveFolder"
        static let copy = "copyToClipboard", save = "saveToFolder", toast = "showToast", sound = "shutterSound"
        static let speed = "scrollSpeed", maxHeight = "maxHeight", maxSeconds = "maxSeconds", setupShown = "setupShown"
    }

    @Published var captureHotkey: Hotkey? { didSet { store(captureHotkey, Keys.captureHotkey) } }
    @Published var fromTopHotkey: Hotkey? { didSet { store(fromTopHotkey, Keys.fromTopHotkey) } }
    /// nil means the Desktop.
    @Published var saveFolder: URL? { didSet { d.set(saveFolder?.path, forKey: Keys.saveFolder) } }
    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: Keys.copy) } }
    @Published var saveToFolder: Bool { didSet { d.set(saveToFolder, forKey: Keys.save) } }
    @Published var showToast: Bool { didSet { d.set(showToast, forKey: Keys.toast) } }
    @Published var shutterSound: Bool { didSet { d.set(shutterSound, forKey: Keys.sound) } }
    @Published var scrollSpeed: ScrollSpeed { didSet { d.set(scrollSpeed.rawValue, forKey: Keys.speed) } }
    @Published var maxHeight: Int { didSet { d.set(maxHeight, forKey: Keys.maxHeight) } }
    @Published var maxSeconds: Int { didSet { d.set(maxSeconds, forKey: Keys.maxSeconds) } }
    @Published var setupShown: Bool { didSet { d.set(setupShown, forKey: Keys.setupShown) } }

    private init() {
        d.register(defaults: [Keys.copy: true, Keys.save: true, Keys.toast: true, Keys.sound: false,
                              Keys.speed: ScrollSpeed.normal.rawValue, Keys.maxHeight: 30_000, Keys.maxSeconds: 60])
        captureHotkey = d.object(forKey: Keys.captureHotkey) == nil ? .defaultCapture : Self.load(d, Keys.captureHotkey)
        fromTopHotkey = Self.load(d, Keys.fromTopHotkey)
        saveFolder = d.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        copyToClipboard = d.bool(forKey: Keys.copy)
        saveToFolder = d.bool(forKey: Keys.save)
        showToast = d.bool(forKey: Keys.toast)
        shutterSound = d.bool(forKey: Keys.sound)
        scrollSpeed = ScrollSpeed(rawValue: d.string(forKey: Keys.speed) ?? "") ?? .normal
        maxHeight = d.integer(forKey: Keys.maxHeight)
        maxSeconds = d.integer(forKey: Keys.maxSeconds)
        setupShown = d.bool(forKey: Keys.setupShown)
    }

    /// A hotkey is stored as Data; "none" is stored as empty Data so it isn't reset to the default.
    private func store(_ h: Hotkey?, _ key: String) {
        d.set(h.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
    private static func load(_ d: UserDefaults, _ key: String) -> Hotkey? {
        guard let data = d.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    var folderURL: URL {
        saveFolder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    func captureOptions(fromTop: Bool) -> CaptureOptions {
        var o = CaptureOptions()
        o.stepFraction = scrollSpeed.stepFraction
        o.settleIntervalMs = scrollSpeed.settleMs
        o.maxHeight = maxHeight
        o.maxSeconds = Double(maxSeconds)
        o.fromTop = fromTop
        return o
    }
}

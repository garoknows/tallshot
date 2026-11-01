import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon's RegisterEventHotKey. Unlike a keyboard monitor, this needs
/// no Input Monitoring permission: macOS tells the app only when its own key combo is pressed.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[key]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Registers (or clears, with nil) hotkey slot `id`. Returns false if macOS refused the combo.
    @discardableResult
    func set(_ id: UInt32, _ hotkey: Hotkey?, action: @escaping () -> Void) -> Bool {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions[id] = action
        guard let hotkey else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: OSType(0x544C5354), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref; return true }
        return false
    }
}

/// The keyboard shortcuts macOS itself has switched on (System Settings → Keyboard → Keyboard
/// Shortcuts), read with Carbon's CopySymbolicHotKeys.
enum SystemShortcuts {
    static func uses(_ hotkey: Hotkey) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return list.contains { d in
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            return code == hotkey.keyCode && (mods & mask) == hotkey.modifiers
        }
    }
}

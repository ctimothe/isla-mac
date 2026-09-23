import AppKit
import Carbon.HIToolbox

/// The three things the keyboard can reach from anywhere, whatever app is in
/// front.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case openPanel
    case showLyrics
    case translateClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: return localized("Open the panel")
        case .showLyrics: return localized("Show the lyrics")
        case .translateClipboard: return localized("Translate the clipboard")
        }
    }

    /// ⌃⌥⌘ and a letter. The first defaults were ⌥⌘I, ⌥⌘T and ⌥⌘L, chosen
    /// because macOS binds none of them system-wide. Apps bind all three:
    /// ⌥⌘I is Web Inspector in Safari and Developer Tools in Chrome, Arc and
    /// Firefox; ⌥⌘L is Downloads in Safari, Chrome and Finder; ⌥⌘T hides
    /// Finder's toolbar. A Carbon hot key wins over the frontmost app's own
    /// shortcut, so Isla took those keys from every browser without saying so.
    /// Browsers bind nothing to Control-Option-Command, which is why global
    /// utilities use it.
    var defaultBinding: HotKeyBinding {
        switch self {
        case .openPanel: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_I), modifiers: HotKeyBinding.defaultModifiers)
        case .showLyrics: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: HotKeyBinding.defaultModifiers)
        case .translateClipboard: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: HotKeyBinding.defaultModifiers)
        }
    }

    var defaultsKey: String { "hotkey.\(rawValue)" }
}

/// A key and its modifiers, in Carbon's terms because `RegisterEventHotKey`
/// takes Carbon's terms.
struct HotKeyBinding: Equatable, Hashable {
    /// A virtual key code, so the binding names the physical key and survives
    /// a layout change. See `GlobalHotKey.init`.
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    /// The binding a key press describes, or nil when it cannot be one.
    ///
    /// It needs ⌘, ⌃ or ⌥. A key with only ⇧, or no modifier, would take a
    /// letter away from every text field on the Mac, because a hot key fires
    /// before the focused field sees the press. A press of a modifier alone
    /// is not a key either.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        guard !Self.modifierKeyCodes.contains(Int(keyCode)) else { return nil }
        var carbon: Int = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(carbon))
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// How macOS writes a shortcut in its own menus: ⌃⌥⇧⌘, then the key.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The key's name on a US keyboard. Fixed rather than read from the
    /// current layout, because macOS menus also show the Latin letter while a
    /// Cyrillic layout is active, and a shortcut should read the same
    /// whichever layout was active when it was set.
    static func keyName(_ keyCode: UInt32) -> String {
        if let name = names[Int(keyCode)] { return name }
        return "#\(keyCode)"
    }

    private static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
        kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
        kVK_CapsLock, kVK_Function,
    ]

    private static let names: [Int: String] = {
        var table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
            kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { table[code] = "F\(index + 1)" }
        return table
    }()
}

// MARK: - Storage

extension HotKeyBinding {
    /// What the user chose for `action`: the default when nothing was ever
    /// set, nil when they cleared it.
    ///
    /// A cleared shortcut is stored as an explicit "none" and not as a missing
    /// key. A missing key means the default, so a shortcut cleared that way
    /// would come back at the next launch.
    static func stored(for action: HotKeyAction, in defaults: UserDefaults) -> HotKeyBinding? {
        guard let value = defaults.object(forKey: action.defaultsKey) else { return action.defaultBinding }
        guard let dictionary = value as? [String: Int],
              let keyCode = dictionary["keyCode"], let modifiers = dictionary["modifiers"],
              keyCode >= 0, modifiers >= 0
        else { return nil }
        return HotKeyBinding(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    static func store(_ binding: HotKeyBinding?, for action: HotKeyAction, in defaults: UserDefaults) {
        guard let binding else {
            defaults.set(Self.clearedMarker, forKey: action.defaultsKey)
            return
        }
        if binding == action.defaultBinding {
            defaults.removeObject(forKey: action.defaultsKey)
        } else {
            defaults.set(
                ["keyCode": Int(binding.keyCode), "modifiers": Int(binding.modifiers)],
                forKey: action.defaultsKey
            )
        }
    }

    static let clearedMarker = "none"
}

// MARK: - Registration

/// A live registration that can be given up. `GlobalHotKey` is the real one.
/// Tests pass their own, because a real one reserves the combination for the
/// whole login session.
@MainActor
protocol HotKeyRegistration: AnyObject {
    func unregister()
}

extension GlobalHotKey: HotKeyRegistration {}

/// Owns the three shortcuts: what each one is bound to, whether macOS
/// accepted it, and changing them from Settings.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    typealias Registrar = @MainActor (HotKeyBinding, @escaping () -> Void) -> HotKeyRegistration?

    /// nil for an action the user cleared.
    @Published private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    /// Bindings macOS refused, usually because another app registered the
    /// combination first. Shown in Settings. Before this, a refused
    /// registration returned nil into an optional nobody read, and the
    /// shortcut did nothing without any sign of why.
    @Published private(set) var refused: Set<HotKeyAction> = []
    /// The action whose shortcut Settings is recording right now.
    @Published private(set) var recording: HotKeyAction?

    private let defaults: UserDefaults
    private let registrar: Registrar
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var registrations: [HotKeyAction: HotKeyRegistration] = [:]

    init(
        defaults: UserDefaults = .standard,
        registrar: @escaping Registrar = { binding, action in
            GlobalHotKey(keyCode: binding.keyCode, modifiers: binding.modifiers, action: action)
        }
    ) {
        self.defaults = defaults
        self.registrar = registrar
        for action in HotKeyAction.allCases {
            if let binding = HotKeyBinding.stored(for: action, in: defaults) {
                bindings[action] = binding
            }
        }
    }

    func install(_ handlers: [HotKeyAction: () -> Void]) {
        self.handlers = handlers
        registerAll()
    }

    /// Binds `action` to `binding`, or clears it when `binding` is nil. A
    /// combination already held by another action moves here, and the other
    /// action is cleared. Two actions on one key cannot both fire, and letting
    /// one of them fail with no sign is how the old defaults behaved.
    func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        if let binding {
            for other in HotKeyAction.allCases where other != action && bindings[other] == binding {
                bindings[other] = nil
                HotKeyBinding.store(nil, for: other, in: defaults)
            }
        }
        bindings[action] = binding
        HotKeyBinding.store(binding, for: action, in: defaults)
        if recording == nil { registerAll() }
    }

    func restoreDefaults() {
        for action in HotKeyAction.allCases {
            defaults.removeObject(forKey: action.defaultsKey)
            bindings[action] = action.defaultBinding
        }
        if recording == nil { registerAll() }
    }

    /// Recording lets every shortcut go until it ends. Otherwise pressing the
    /// combination already bound, to keep it or to move it, would fire it
    /// instead of being recorded.
    func beginRecording(_ action: HotKeyAction) {
        recording = action
        unregisterAll()
    }

    func endRecording() {
        guard recording != nil else { return }
        recording = nil
        registerAll()
    }

    func teardown() {
        recording = nil
        unregisterAll()
    }

    private func registerAll() {
        unregisterAll()
        var refused: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let binding = bindings[action], let handler = handlers[action] else { continue }
            if let registration = registrar(binding, handler) {
                registrations[action] = registration
            } else {
                refused.insert(action)
                Log.app.error("shortcut \(binding.displayString, privacy: .public) for \(action.rawValue, privacy: .public) was refused")
            }
        }
        if refused != self.refused { self.refused = refused }
    }

    private func unregisterAll() {
        registrations.values.forEach { $0.unregister() }
        registrations.removeAll()
    }
}

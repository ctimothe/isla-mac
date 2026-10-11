import AppKit
import Carbon.HIToolbox

/// An optional feature that owns hot keys. Its keys exist only while it is
/// on: `HotKeyCenter` registers an action only when the action's feature is
/// enabled, so a key bound while the feature is off stays free for every
/// other app (Prompter spec section 4).
enum HotKeyFeature: String, Sendable {
    case prompter
}

/// The things the keyboard can reach from anywhere, whatever app is in front:
/// the core three, always there, and the Prompter's two, there only while its
/// switch is on.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case openPanel
    case showLyrics
    case translateClipboard
    /// Prompter spec 5.4: start, pause or resume. Release 2 adds faster and
    /// slower; they are not cases until their speed control exists, because a
    /// case is a row in Settings and a key somebody can press.
    case prompterToggle
    case prompterStop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: return localized("Open the panel")
        case .showLyrics: return localized("Show the lyrics")
        case .translateClipboard: return localized("Translate the clipboard")
        case .prompterToggle: return localized("Start or pause the Prompter")
        case .prompterStop: return localized("Stop the Prompter")
        }
    }

    /// The optional feature this action belongs to, nil for the core three.
    var feature: HotKeyFeature? {
        switch self {
        case .openPanel, .showLyrics, .translateClipboard: return nil
        case .prompterToggle, .prompterStop: return .prompter
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
    ///
    /// One overlap is known and accepted: ⌃⌥ is VoiceOver's VO key, so with
    /// VoiceOver running, ⌃⌥⌘L and ⌃⌥⌘T are also VO-⌘-L and VO-⌘-T, its
    /// next-link and next-table commands. Which one wins has not been checked
    /// on hardware (see `checklist.md`). Either way a VoiceOver user can move
    /// all three in Settings, from the keyboard.
    ///
    /// The Prompter's ⌃⌥⌘P and ⌃⌥⌘S (spec 5.4) follow the same reasoning and
    /// carry the same VoiceOver overlap (E-52). Neither is a plain Escape,
    /// which a session never claims: during a Keynote or Zoom presentation
    /// Escape belongs to the app in front, and ends its slideshow.
    var defaultBinding: HotKeyBinding {
        switch self {
        case .openPanel: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_I), modifiers: HotKeyBinding.defaultModifiers)
        case .showLyrics: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: HotKeyBinding.defaultModifiers)
        case .translateClipboard: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: HotKeyBinding.defaultModifiers)
        case .prompterToggle: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: HotKeyBinding.defaultModifiers)
        case .prompterStop: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: HotKeyBinding.defaultModifiers)
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
    /// It needs two of ⌘, ⌃ and ⌥. A hot key fires before the focused app
    /// sees the press, so anything less takes keys away from everything:
    /// ⌘ alone owns Copy, Paste and Quit in every app (a recorded ⌘V would
    /// have broken paste Mac-wide, and been saved), ⌃ alone owns the
    /// text-field motions (⌃A, ⌃E), and macOS 15 refuses ⌥ and ⌥⇧ hot keys
    /// outright. A press of a modifier alone is not a key either.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let primaries = [NSEvent.ModifierFlags.command, .control, .option].filter { flags.contains($0) }
        guard primaries.count >= 2 else { return nil }
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

    /// The key's name on the user's Latin keyboard layout, the way macOS menus
    /// write it, so on QWERTZ the key a shortcut was recorded on reads "Z" and
    /// not the US "Y" (G-039). A Cyrillic layout is not asked, because macOS
    /// menus also show the Latin letter while one is active. Keys a layout
    /// cannot print as one character (arrows, F-keys, Return) keep the glyph
    /// from the table, and so does everything when the layout cannot be read.
    static func keyName(_ keyCode: UInt32) -> String {
        if let name = KeyboardLayoutNames.name(for: Int(keyCode)) { return name }
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
    static func stored(for action: HotKeyAction, in defaults: Defaults) -> HotKeyBinding? {
        guard let value = defaults.object(forKey: action.defaultsKey) else { return action.defaultBinding }
        guard let dictionary = value as? [String: Int],
              let keyCode = dictionary["keyCode"], let modifiers = dictionary["modifiers"],
              keyCode >= 0, modifiers >= 0
        else { return nil }
        return HotKeyBinding(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    static func store(_ binding: HotKeyBinding?, for action: HotKeyAction, in defaults: Defaults) {
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

/// Owns the shortcuts: what each one is bound to, whether macOS accepted it,
/// whether its feature is on, and changing them from Settings.
///
/// An action whose feature is off is *absent*: it is not registered, cannot
/// be recorded, set or restored, takes no part in moving a key from one
/// action to another, and is never written. Its stored binding is read and
/// kept, untouched, for when the feature comes back.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    typealias Registrar = @MainActor (HotKeyBinding, @escaping () -> Void) -> HotKeyRegistration?

    /// nil for an action the user cleared.
    @Published private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    /// Bindings macOS refused. Shown in Settings. Before this, a refused
    /// registration returned nil into an optional nobody read, and the
    /// shortcut did nothing without any sign of why.
    ///
    /// Not a conflict detector. Carbon hot keys are registered non-exclusive,
    /// and a non-exclusive registration succeeds even when another app holds
    /// the same combination, so a clash with another app is invisible from
    /// here. What does come back refused is what macOS itself will not
    /// register, and the Settings note says exactly that.
    @Published private(set) var refused: Set<HotKeyAction> = []
    /// The action whose shortcut Settings is recording right now.
    @Published private(set) var recording: HotKeyAction?

    /// The last combination one action took from another, for the note in
    /// Settings. Cleared by the next recording or a restore of the defaults.
    struct Displaced: Equatable {
        let binding: HotKeyBinding
        let from: HotKeyAction
        let to: HotKeyAction
    }
    @Published private(set) var displaced: Displaced?

    /// Optional features that are on. Empty until someone says otherwise, so
    /// a center nobody told about the Prompter registers only the core three:
    /// the safe reading of "not known to be on" is off.
    @Published private(set) var enabledFeatures: Set<HotKeyFeature> = []

    /// Available actions that are not registered because an earlier action
    /// already holds the same key, mapped to that holder. Only reachable when
    /// a core action took a key while the feature owning it was off: the move
    /// is not made then (the loser would be an action the user cannot see),
    /// so when the feature returns both want the key. The earlier action in
    /// `allCases` order keeps it. Registering both is not an option: Carbon
    /// registrations are non-exclusive, so one press would fire both.
    @Published private(set) var shadowed: [HotKeyAction: HotKeyAction] = [:]

    private let defaults: Defaults
    private let registrar: Registrar
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var registrations: [HotKeyAction: HotKeyRegistration] = [:]
    /// The one key monitor a recording uses. Owned here and not by a Settings
    /// row, because a row that started a recording could lose track of its
    /// monitor: clicking a second row ended the first row's recording
    /// without removing its monitor, which then swallowed every key the app
    /// received for the rest of the session and could record ⌘V as a global
    /// shortcut.
    private var monitor: Any?
    /// What a refused press does. A beep, like System Settings' own shortcut
    /// fields; tests silence it.
    var refuseSound: () -> Void = { NSSound.beep() }

    var isListening: Bool { monitor != nil }

    init(
        defaults: Defaults = UserDefaults.standard,
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

    /// Whether `action` exists right now: a core action always, a feature's
    /// action only while its feature is on.
    func isAvailable(_ action: HotKeyAction) -> Bool {
        action.feature.map(enabledFeatures.contains) ?? true
    }

    /// The actions Settings, the restore row and Diagnostics should show.
    var availableActions: [HotKeyAction] {
        HotKeyAction.allCases.filter(isAvailable)
    }

    /// A feature's switch changed. Its keys are registered or let go at once,
    /// so turning the Prompter off frees ⌃⌥⌘P for other apps without a
    /// relaunch (spec 4, E-45). A recording of one of its keys ends with it,
    /// taking its key-swallowing monitor along; a note about one of its keys
    /// goes too, since it would name an action that is no longer there.
    func setFeature(_ feature: HotKeyFeature, enabled: Bool) {
        guard enabledFeatures.contains(feature) != enabled else { return }
        if enabled { enabledFeatures.insert(feature) } else { enabledFeatures.remove(feature) }
        if !enabled, let note = displaced, note.from.feature == feature || note.to.feature == feature {
            displaced = nil
        }
        if !enabled, recording?.feature == feature {
            endRecording()
            return
        }
        if recording == nil { registerAll() }
    }

    /// Binds `action` to `binding`, or clears it when `binding` is nil. A
    /// combination already held by another action moves here, and the other
    /// action is cleared. Two actions on one key cannot both fire, and letting
    /// one of them fail with no sign is how the old defaults behaved.
    ///
    /// The move is kept (it is what System Settings does) but no longer
    /// silent: `displaced` says which action lost its shortcut, because
    /// "Open the panel" is the keyboard and VoiceOver way in and used to be
    /// unbound with no sign (J-023).
    ///
    /// An absent action (its feature off) is left alone, as a target and as a
    /// loser: nothing writes behind a switch that is off.
    func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        guard isAvailable(action) else { return }
        displaced = nil
        if let binding {
            for other in HotKeyAction.allCases where other != action && isAvailable(other) && bindings[other] == binding {
                bindings[other] = nil
                HotKeyBinding.store(nil, for: other, in: defaults)
                displaced = Displaced(binding: binding, from: other, to: action)
            }
        }
        bindings[action] = binding
        HotKeyBinding.store(binding, for: action, in: defaults)
        if recording == nil { registerAll() }
    }

    /// The available actions only: Restore Default Shortcuts restores what
    /// Settings shows, and while the Prompter is off that is the core three.
    func restoreDefaults() {
        displaced = nil
        for action in availableActions {
            defaults.removeObject(forKey: action.defaultsKey)
            bindings[action] = action.defaultBinding
        }
        if recording == nil { registerAll() }
    }

    /// Recording lets every shortcut go until it ends. Otherwise pressing the
    /// combination already bound, to keep it or to move it, would fire it
    /// instead of being recorded. Every key press goes to `record` and none
    /// reaches the panel, until the recording ends.
    func beginRecording(_ action: HotKeyAction) {
        guard isAvailable(action) else { return }
        removeMonitor()
        displaced = nil
        recording = action
        unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.record(keyCode: event.keyCode, flags: event.modifierFlags) }
            return nil
        }
    }

    /// One key press while recording: Esc cancels, Delete clears the
    /// shortcut, and a usable combination is kept. Anything else beeps and
    /// recording goes on. Returns whether the recording ended.
    @discardableResult
    func record(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let action = recording else { return false }
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.intersection([.command, .control, .option]).isEmpty
        if plain, Int(keyCode) == kVK_Escape {
            endRecording()
            return true
        }
        if plain, Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete {
            setBinding(nil, for: action)
            endRecording()
            return true
        }
        guard let binding = HotKeyBinding(keyCode: keyCode, flags: flags) else {
            refuseSound()
            return false
        }
        setBinding(binding, for: action)
        endRecording()
        return true
    }

    /// Ends a recording, whoever asks: the row, Esc, the panel losing the
    /// keyboard, a rebuild, or quitting. Safe to call when none is running.
    func endRecording() {
        guard recording != nil else { return }
        removeMonitor()
        recording = nil
        registerAll()
    }

    func teardown() {
        removeMonitor()
        recording = nil
        unregisterAll()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func registerAll() {
        unregisterAll()
        var refused: Set<HotKeyAction> = []
        var shadowed: [HotKeyAction: HotKeyAction] = [:]
        var holders: [HotKeyBinding: HotKeyAction] = [:]
        for action in availableActions {
            guard let binding = bindings[action], let handler = handlers[action] else { continue }
            if let holder = holders[binding] {
                shadowed[action] = holder
                continue
            }
            if let registration = registrar(binding, handler) {
                registrations[action] = registration
                holders[binding] = action
            } else {
                refused.insert(action)
                Log.app.error("macOS refused shortcut \(binding.displayString, privacy: .public) for \(action.rawValue, privacy: .public)")
            }
        }
        if refused != self.refused { self.refused = refused }
        if shadowed != self.shadowed { self.shadowed = shadowed }
    }

    private func unregisterAll() {
        registrations.values.forEach { $0.unregister() }
        registrations.removeAll()
    }
}

import Combine
import CoreFoundation
import Foundation

// Foundation and Combine only, like the rest of the prompter's model layer.
// Two things live here: the `prompter.*` settings of spec 12.2, typed and
// clamped, and `PrompterFeature`, the switch of spec section 4 that decides
// whether any of the Prompter exists at all. Both read and write through the
// `Defaults` seam, so a test hands them an `InMemoryDefaults` and never reaches
// `UserDefaults.standard`.

// MARK: - Defaults seam

/// The three verbs the Prompter (and the hot-key store) need from a defaults
/// domain. `UserDefaults` already has all three with these exact signatures,
/// so it conforms with no code; tests use `InMemoryDefaults`.
///
/// Deliberately untyped (`Any?`), because the typing is the point of the
/// readers below: a value of the wrong type from a hand-edited plist has to be
/// *seen* as the wrong type, and `UserDefaults.bool(forKey:)` or
/// `double(forKey:)` would quietly coerce the string "YES" or "3" instead.
protocol Defaults: AnyObject {
    func object(forKey defaultName: String) -> Any?
    /// `nil` removes the key, as it does for `UserDefaults`.
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: Defaults {}

/// A defaults domain that lives and dies with the object. For tests, so none
/// of them writes to the machine's real defaults, and for anything that wants
/// settings without persistence.
///
/// `writes` lists every key set or removed, in order. The gating contract of
/// spec section 4 ("no `prompter.*` default is written except the switch
/// itself") is a statement about writes, not about what is stored at the end,
/// so it has to be checked against this log.
final class InMemoryDefaults: Defaults {
    private(set) var storage: [String: Any]
    private(set) var writes: [String] = []

    init(_ storage: [String: Any] = [:]) {
        self.storage = storage
    }

    func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        writes.append(defaultName)
        storage[defaultName] = nil
    }

    /// Forgets the log, not the values: for a test that seeds the domain and
    /// then asserts on what the code under test writes.
    func resetWrites() {
        writes.removeAll()
    }
}

// MARK: - Strict readers

/// How a stored value is read: by its real type, or not at all.
///
/// Spec 12.2 and E-56: non-finite numbers, wrong types, unknown enum values
/// and out-of-range numbers load as the default (or clamp), never crash and
/// never write back. The old `TeleprompterStore` read a NaN from a hand-edited
/// plist and overflowed the stack; these readers are the fix, and the clamps
/// that follow them are the second half.
enum StrictDefaults {
    /// A genuine property-list boolean. An integer 1 is a number, not a
    /// switch: `CFBoolean` is a distinct type in a plist, and anything else in
    /// a Bool's place was put there by hand or by a bug.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    /// A number that is not a boolean. May be non-finite: the caller decides
    /// what NaN means for its key (always the default, here).
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    /// A whole number, from an integer or an integral double (3.0 is 3);
    /// 2.5 and NaN are not integers.
    static func int(_ value: Any?) -> Int? {
        guard let double = double(value), double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func enumeration<T: RawRepresentable>(_ value: Any?, as type: T.Type) -> T? where T.RawValue == String {
        string(value).flatMap(T.init(rawValue:))
    }

    /// `true as NSNumber` is the `kCFBooleanTrue` singleton, whose type is
    /// `CFBoolean`; every other number has type `CFNumber`. Asking `as? Bool`
    /// instead would accept the integers 0 and 1 too.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: - Options

/// Spec 12.2 `prompter.fontSize`. The point sizes are the spec's starting
/// values, to be tuned on hardware; the stored value is the name, so tuning
/// a size never invalidates what the user chose.
enum PrompterFontSize: String, CaseIterable, Sendable {
    case xs, sm, lg, xl

    var points: Double {
        switch self {
        case .xs: return 18
        case .sm: return 22
        case .lg: return 26
        case .xl: return 32
        }
    }
}

/// Spec 12.2 `prompter.fontFamily`. `dyslexia` is OpenDyslexic; with the font
/// absent the stage falls back to the rounded system face (E-32, the stage's
/// task), so the setting itself never fails.
enum PrompterFontFamily: String, CaseIterable, Sendable {
    case sans, serif, mono, dyslexia
}

/// Spec 12.2 `prompter.highlight` and `prompter.cueColor`. Names only: the
/// colours themselves are design tokens (spec 12.2 "through the design
/// tokens, not literal values in views"), resolved where the stage draws.
enum PrompterTint: String, CaseIterable, Sendable {
    case white, yellow, green, blue, pink, orange
}

/// Spec 12.2 `prompter.cueBrightness`; the opacities it maps to are the
/// stage's (spec 10.1) and come from the design pass.
enum PrompterCueBrightness: String, CaseIterable, Sendable {
    case dim, low, medium, bright
}

/// Spec 12.2 `prompter.readingPosition` and 10.3.
enum PrompterReadingPosition: String, CaseIterable, Sendable {
    case centered, nearTop
}

// MARK: - Values

/// Every release 1 setting of spec 12.2, already clamped. A plain value, so
/// the session and the stage can take a snapshot and a test can compare one.
///
/// Release 2 to 4 rows (`micUID`, `speechLocale`, `allowAppleSpeech`,
/// `lastDocumentFolder`) are absent on purpose: a setting with no feature
/// behind it becomes a control for something that does not work. They arrive
/// with their engines, as `PrompterGuidanceMode` gains `voice` and `follow`.
struct PrompterSettingsValues: Equatable, Sendable {
    static let columnWidthRange: ClosedRange<Double> = 280...560
    static let defaultColumnWidth: Double = 360
    /// The same set and default the session enforces
    /// (`PrompterSession.allowedCountdowns` and `defaultCountdown`, ruling
    /// 20.2 #9), as an ordered list for a picker. Written out rather than read
    /// from the session, whose statics are main-actor isolated while this
    /// value type is not; `PrompterSettingsTests` holds the two equal.
    static let autoNextDelays = [0, 1, 3, 5]
    static let defaultAutoNextDelay = 3

    var mode: PrompterGuidanceMode = .classic
    var speed: Double = PromptClock.defaultSpeed
    var fontSize: PrompterFontSize = .lg
    var fontFamily: PrompterFontFamily = .sans
    var highlight: PrompterTint = .white
    var cueColor: PrompterTint = .white
    var cueBrightness: PrompterCueBrightness = .dim
    var readingPosition: PrompterReadingPosition = .centered
    var columnWidth: Double = PrompterSettingsValues.defaultColumnWidth
    var paragraphDividers = false
    var showLastSpoken = true
    var showElapsed = true
    var keepAwake = true
    var autoNext = false
    var autoNextDelay: Int = PrompterSettingsValues.defaultAutoNextDelay

    static let defaults = PrompterSettingsValues()

    /// Reads every key and clamps it. Writes nothing: a bad value stays in the
    /// plist and is read as the default every time, rather than being
    /// "corrected" into a write that a second bug could turn into a loop
    /// (E-56 "no feedback loop"). The next real change from the user
    /// overwrites it.
    static func load(from store: Defaults) -> PrompterSettingsValues {
        typealias Key = PrompterSettings.Key
        let d = PrompterSettingsValues.defaults
        func read<T>(_ key: String, _ reader: (Any?) -> T?) -> T? { reader(store.object(forKey: key)) }

        var values = PrompterSettingsValues()
        // A mode this release does not have ("voice" written by release 2,
        // read after a downgrade) is Classic for now and is left stored for
        // the release that understands it.
        values.mode = read(Key.mode) { StrictDefaults.enumeration($0, as: PrompterGuidanceMode.self) } ?? d.mode
        values.speed = read(Key.speed, StrictDefaults.double).map(clampedSpeed) ?? d.speed
        values.fontSize = read(Key.fontSize) { StrictDefaults.enumeration($0, as: PrompterFontSize.self) } ?? d.fontSize
        values.fontFamily = read(Key.fontFamily) { StrictDefaults.enumeration($0, as: PrompterFontFamily.self) } ?? d.fontFamily
        values.highlight = read(Key.highlight) { StrictDefaults.enumeration($0, as: PrompterTint.self) } ?? d.highlight
        values.cueColor = read(Key.cueColor) { StrictDefaults.enumeration($0, as: PrompterTint.self) } ?? d.cueColor
        values.cueBrightness = read(Key.cueBrightness) { StrictDefaults.enumeration($0, as: PrompterCueBrightness.self) } ?? d.cueBrightness
        values.readingPosition = read(Key.readingPosition) { StrictDefaults.enumeration($0, as: PrompterReadingPosition.self) } ?? d.readingPosition
        values.columnWidth = read(Key.columnWidth, StrictDefaults.double).map(clampedColumnWidth) ?? d.columnWidth
        values.paragraphDividers = read(Key.paragraphDividers, StrictDefaults.bool) ?? d.paragraphDividers
        values.showLastSpoken = read(Key.showLastSpoken, StrictDefaults.bool) ?? d.showLastSpoken
        values.showElapsed = read(Key.showElapsed, StrictDefaults.bool) ?? d.showElapsed
        values.keepAwake = read(Key.keepAwake, StrictDefaults.bool) ?? d.keepAwake
        values.autoNext = read(Key.autoNext, StrictDefaults.bool) ?? d.autoNext
        values.autoNextDelay = read(Key.autoNextDelay, StrictDefaults.int).map(clampedAutoNextDelay) ?? d.autoNextDelay
        return values
    }

    // MARK: Clamps (shared by load and write)

    /// 0.5...8 in steps of 0.5, NaN and infinity to 3.0: the clock's own rule
    /// (ruling 20.2 #3), called rather than repeated so the two cannot drift.
    static func clampedSpeed(_ value: Double) -> Double {
        PromptClock.clampedSpeed(value)
    }

    /// 280...560, NaN and infinity to 360. No step: the spec gives none, and
    /// the stage further limits it to the body less margins at layout time.
    static func clampedColumnWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultColumnWidth }
        return min(max(value, columnWidthRange.lowerBound), columnWidthRange.upperBound)
    }

    /// One of 0, 1, 3, 5; anything else is 3 (ruling 20.2 #9). Not "nearest":
    /// 4 is not obviously 3 or 5, and the session already reads an outsider
    /// as 3, so the stored setting must agree with it.
    static func clampedAutoNextDelay(_ value: Int) -> Int {
        autoNextDelays.contains(value) ? value : defaultAutoNextDelay
    }
}

// MARK: - Settings

/// The live, observable `prompter.*` settings. Loaded (and clamped) once at
/// construction; each setter clamps, writes its own key only when the value
/// actually changes, and announces the change for the Settings rows and the
/// stage.
///
/// Constructing one writes nothing, so it is harmless to build. It is still
/// built only while the switch is on, by `PrompterFeature`: with the switch
/// off nothing of the Prompter exists, settings included (spec section 4).
@MainActor
final class PrompterSettings: ObservableObject {
    /// The key names of spec 12.2. `settings` lists every release 1 setting
    /// and is what Reset clears; the switch is separate because it is the
    /// feature's, not a setting Reset could turn off.
    enum Key {
        static let enabled = "prompter.enabled"
        static let mode = "prompter.mode"
        static let speed = "prompter.speed"
        static let fontSize = "prompter.fontSize"
        static let fontFamily = "prompter.fontFamily"
        static let highlight = "prompter.highlight"
        static let cueColor = "prompter.cueColor"
        static let cueBrightness = "prompter.cueBrightness"
        static let readingPosition = "prompter.readingPosition"
        static let columnWidth = "prompter.columnWidth"
        static let paragraphDividers = "prompter.paragraphDividers"
        static let showLastSpoken = "prompter.showLastSpoken"
        static let showElapsed = "prompter.showElapsed"
        static let keepAwake = "prompter.keepAwake"
        static let autoNext = "prompter.autoNext"
        static let autoNextDelay = "prompter.autoNextDelay"

        static let settings = [
            mode, speed, fontSize, fontFamily, highlight, cueColor, cueBrightness,
            readingPosition, columnWidth, paragraphDividers, showLastSpoken,
            showElapsed, keepAwake, autoNext, autoNextDelay,
        ]
    }

    private(set) var values: PrompterSettingsValues
    private let store: Defaults

    init(defaults: Defaults) {
        store = defaults
        values = PrompterSettingsValues.load(from: defaults)
    }

    var mode: PrompterGuidanceMode {
        get { values.mode }
        set { update(\.mode, newValue, Key.mode, newValue.rawValue) }
    }

    var speed: Double {
        get { values.speed }
        set {
            let clamped = PrompterSettingsValues.clampedSpeed(newValue)
            update(\.speed, clamped, Key.speed, clamped)
        }
    }

    var fontSize: PrompterFontSize {
        get { values.fontSize }
        set { update(\.fontSize, newValue, Key.fontSize, newValue.rawValue) }
    }

    var fontFamily: PrompterFontFamily {
        get { values.fontFamily }
        set { update(\.fontFamily, newValue, Key.fontFamily, newValue.rawValue) }
    }

    var highlight: PrompterTint {
        get { values.highlight }
        set { update(\.highlight, newValue, Key.highlight, newValue.rawValue) }
    }

    var cueColor: PrompterTint {
        get { values.cueColor }
        set { update(\.cueColor, newValue, Key.cueColor, newValue.rawValue) }
    }

    var cueBrightness: PrompterCueBrightness {
        get { values.cueBrightness }
        set { update(\.cueBrightness, newValue, Key.cueBrightness, newValue.rawValue) }
    }

    var readingPosition: PrompterReadingPosition {
        get { values.readingPosition }
        set { update(\.readingPosition, newValue, Key.readingPosition, newValue.rawValue) }
    }

    var columnWidth: Double {
        get { values.columnWidth }
        set {
            let clamped = PrompterSettingsValues.clampedColumnWidth(newValue)
            update(\.columnWidth, clamped, Key.columnWidth, clamped)
        }
    }

    var paragraphDividers: Bool {
        get { values.paragraphDividers }
        set { update(\.paragraphDividers, newValue, Key.paragraphDividers, newValue) }
    }

    var showLastSpoken: Bool {
        get { values.showLastSpoken }
        set { update(\.showLastSpoken, newValue, Key.showLastSpoken, newValue) }
    }

    var showElapsed: Bool {
        get { values.showElapsed }
        set { update(\.showElapsed, newValue, Key.showElapsed, newValue) }
    }

    var keepAwake: Bool {
        get { values.keepAwake }
        set { update(\.keepAwake, newValue, Key.keepAwake, newValue) }
    }

    var autoNext: Bool {
        get { values.autoNext }
        set { update(\.autoNext, newValue, Key.autoNext, newValue) }
    }

    var autoNextDelay: Int {
        get { values.autoNextDelay }
        set {
            let clamped = PrompterSettingsValues.clampedAutoNextDelay(newValue)
            update(\.autoNextDelay, clamped, Key.autoNextDelay, clamped)
        }
    }

    /// Spec 5.3 Reset Prompter Settings: every setting back to its default by
    /// removing its key, so a later release's different default applies too.
    /// Scripts are the library's and are not touched; neither is the switch.
    func reset() {
        objectWillChange.send()
        for key in Key.settings { store.removeObject(forKey: key) }
        values = .defaults
    }

    /// The one write path. Compares the clamped value with the one in force,
    /// so setting what is already there (a picker re-asserting its selection
    /// on appear) writes and announces nothing.
    private func update<T: Equatable>(
        _ path: WritableKeyPath<PrompterSettingsValues, T>, _ value: T, _ key: String, _ stored: Any
    ) {
        guard values[keyPath: path] != value else { return }
        objectWillChange.send()
        values[keyPath: path] = value
        store.set(stored, forKey: key)
    }
}

// MARK: - The feature switch

/// What exists while the switch is on and nothing else does: the settings, the
/// library and the session. One value so that "off" is a single `nil` rather
/// than three things each remembering to be absent.
@MainActor
struct PrompterParts {
    let settings: PrompterSettings
    let library: PrompterLibrary
    let session: PrompterSession
}

/// The Prompter's switch, `prompter.enabled` (spec section 4). Off by default,
/// and while off the feature is **absent, not hidden**: `parts` is nil, so no
/// settings object, library or session exists; no file has been read; no
/// timer, observer or power assertion has been made; and nothing but this key
/// is ever written for it.
///
/// Consumers:
/// - the tab, the rail, the Welcome legend and the Settings section read
///   `isEnabled` (T5, T9);
/// - `HotKeyCenter` follows `onChange` through `setFeature(.prompter, …)`,
///   wired in `AppDelegate`, so the two hot keys come and go live;
/// - the controller (T6) replaces `endSession` with its own Stop path and
///   follows `onChange` to remove its surfaces.
///
/// The order of a change is fixed here and not left to subscribers. Turning
/// off: the live session is stopped first while every part still exists
/// (spec 7.1 "Switch turned off: any → ended, before surfaces are removed"),
/// the library is flushed (12.1), the parts are dropped, the key is written,
/// and only then are subscribers told, so a subscriber never sees a session
/// still running after "off". Turning on: the key is written, the parts are
/// built and the library loaded, then subscribers are told.
@MainActor
final class PrompterFeature: ObservableObject {
    static let enabledKey = PrompterSettings.Key.enabled

    @Published private(set) var isEnabled: Bool
    @Published private(set) var parts: PrompterParts?

    /// How a live session is ended when the switch turns off. The default is
    /// the session's own Stop; the controller (T6) replaces it with the path
    /// its Stop button takes, so the panel lets go exactly as it does for a
    /// Stop. Must end the session synchronously. Whatever it does, the feature
    /// calls `stop()` itself afterwards, which is a no-op on an ended session,
    /// so no session can outlive the switch through a hook that forgot.
    var endSession: @MainActor (PrompterSession) -> Void = { $0.stop() }

    private let store: Defaults
    private let makeParts: @MainActor (Defaults) -> PrompterParts
    /// In subscription order. Not a `PassthroughSubject`: Combine does not
    /// promise the order a subject delivers to its subscribers, and the first
    /// version of this switch, built on one, told the controller before the
    /// hot keys on one run and after them on the next.
    private var handlers: [(id: Int, run: @MainActor (Bool) -> Void)] = []
    private var nextHandlerID = 0

    /// Reads the switch and nothing else. While off this is the only work the
    /// Prompter does at launch. While on, the parts are built (and the library
    /// read) at once, so the tab has its scripts when it first shows.
    init(defaults: Defaults, makeParts: @escaping @MainActor (Defaults) -> PrompterParts) {
        store = defaults
        self.makeParts = makeParts
        let enabled = Self.storedEnabled(in: defaults)
        isEnabled = enabled
        parts = nil
        if enabled { parts = build() }
    }

    /// The app's own switch: the real defaults, Application Support, the main
    /// queue and the real power assertion, all reached only through the
    /// factory, so none of them is touched while the switch is off.
    static func live(defaults: Defaults = UserDefaults.standard) -> PrompterFeature {
        PrompterFeature(defaults: defaults) { defaults in
            PrompterParts(
                settings: PrompterSettings(defaults: defaults),
                library: PrompterLibrary(),
                session: PrompterSession()
            )
        }
    }

    /// The stored switch, read strictly: anything but a genuine `true` is off.
    /// A switch that gates file reads and, in later releases, the microphone
    /// must not be turned on by a stray integer or the string "YES".
    static func storedEnabled(in defaults: Defaults) -> Bool {
        StrictDefaults.bool(defaults.object(forKey: enabledKey)) ?? false
    }

    /// Turns the feature on or off. Setting the value already in force does
    /// nothing at all: no write, no rebuild, no notification.
    func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            store.set(true, forKey: Self.enabledKey)
            parts = build()
            isEnabled = true
        } else {
            if let parts {
                if parts.session.state.isLive { endSession(parts.session) }
                parts.session.stop()
                parts.library.flush()
            }
            parts = nil
            isEnabled = false
            store.set(false, forKey: Self.enabledKey)
        }
        // A snapshot, so a handler that cancels itself (or another) while
        // being told does not disturb this pass.
        for handler in handlers { handler.run(enabled) }
    }

    /// Calls `handler` after each change has fully happened (see the type's
    /// note for the order), on the main actor, in the order the handlers were
    /// added, until the returned token is cancelled or released. Not called
    /// for the initial state: a subscriber reads `isEnabled` once when it
    /// subscribes, as `AppDelegate` does.
    func onChange(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        nextHandlerID += 1
        let id = nextHandlerID
        handlers.append((id, handler))
        return AnyCancellable { [weak self] in
            // A token is normally released on the main actor by the object
            // that holds it; one released elsewhere hops there rather than
            // touching the list from another thread.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.removeHandler(id) }
            } else {
                Task { @MainActor in self?.removeHandler(id) }
            }
        }
    }

    private func removeHandler(_ id: Int) {
        handlers.removeAll { $0.id == id }
    }

    private func build() -> PrompterParts {
        let parts = makeParts(store)
        // Loaded here so "on" means the scripts are there to show. A missing
        // file is an empty library and is not created by this (E-53).
        parts.library.load()
        return parts
    }
}

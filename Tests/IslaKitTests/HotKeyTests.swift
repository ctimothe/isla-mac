import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// The shortcuts are the only way into a panel that never activates, so each
/// one has to be something no other app owns, and one the user can move when
/// it is taken anyway.
@MainActor
final class HotKeyTests: XCTestCase {
    /// In memory, per test. These used to be a private suite of the real
    /// defaults removed through `UserDefaults.standard` at teardown; a crash
    /// between the two left the suite on disk. `HotKeyCenter` takes the
    /// `Defaults` seam now, so no test reaches the machine's defaults at all.
    private var defaults = InMemoryDefaults()

    /// ⌥⌘I is Web Inspector in Safari and Developer Tools in Chrome, ⌥⌘L is
    /// Downloads, ⌥⌘T hides Finder's toolbar. A Carbon hot key wins over the
    /// app in front, so none of those may come back as a default.
    func testNoDefaultTakesAKeyTheBrowsersOrFinderUse() {
        let taken: Set<HotKeyBinding> = [
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(optionKey | cmdKey)),
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey)),
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | cmdKey)),
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey | cmdKey)),
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | cmdKey)),
        ]
        for action in HotKeyAction.allCases {
            XCTAssertFalse(taken.contains(action.defaultBinding), "\(action) defaults to a key an app already owns")
            XCTAssertEqual(action.defaultBinding.modifiers, HotKeyBinding.defaultModifiers)
        }
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.defaultBinding)).count, HotKeyAction.allCases.count)
    }

    func testTheDefaultsReadTheWayMacOSWritesThem() {
        XCTAssertEqual(HotKeyAction.openPanel.defaultBinding.displayString, "⌃⌥⌘I")
        XCTAssertEqual(HotKeyAction.showLyrics.defaultBinding.displayString, "⌃⌥⌘L")
        XCTAssertEqual(HotKeyAction.translateClipboard.defaultBinding.displayString, "⌃⌥⌘T")
        XCTAssertEqual(HotKeyAction.prompterToggle.defaultBinding.displayString, "⌃⌥⌘P")
        XCTAssertEqual(HotKeyAction.prompterStop.defaultBinding.displayString, "⌃⌥⌘S")
        let shifted = HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey | cmdKey))
        XCTAssertEqual(shifted.displayString, "⇧⌘F5")
    }

    /// A hot key fires before the focused app sees the press, so it needs two
    /// of ⌘, ⌃ and ⌥. ⌘V recorded as a shortcut would break paste Mac-wide,
    /// ⌃A would take a text-field motion, and macOS refuses ⌥ and ⌥⇧ alone.
    func testAPressNeedsTwoOfCommandControlAndOption() {
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: []))
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.shift]))
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_V), flags: [.command]), "⌘V is Paste everywhere")
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_N), flags: [.command, .shift]))
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_A), flags: [.control]), "⌃A moves to the line's start")
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.option, .shift]), "macOS refuses ⌥⇧ hot keys")
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_Command), flags: [.command, .option]), "a modifier alone is not a key")
        let recorded = HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .option, .shift])
        XCTAssertEqual(recorded?.displayString, "⌃⌥⇧K")
        XCTAssertNotNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .command]))
    }

    /// One monitor for every row. Starting a second recording used to end the
    /// first row's without removing its monitor, which then swallowed every
    /// key for the rest of the session.
    func testRecordingUsesOneMonitorWhicheverRowStartsIt() {
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        center.beginRecording(.openPanel)
        XCTAssertTrue(center.isListening)
        center.beginRecording(.showLyrics)
        XCTAssertEqual(center.recording, .showLyrics)
        XCTAssertTrue(center.isListening)
        center.endRecording()
        XCTAssertFalse(center.isListening, "the monitor goes with the recording")
        XCTAssertNil(center.recording)
    }

    func testEscapeCancelsDeleteClearsAndAGoodPressIsKept() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.refuseSound = {}
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))

        center.beginRecording(.openPanel)
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_Escape), flags: []))
        XCTAssertEqual(center.bindings[.openPanel], HotKeyAction.openPanel.defaultBinding, "Esc changes nothing")
        XCTAssertFalse(center.isListening)

        center.beginRecording(.openPanel)
        XCTAssertFalse(center.record(keyCode: UInt16(kVK_ANSI_V), flags: [.command]), "⌘V is refused and recording goes on")
        XCTAssertTrue(center.isListening)
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_ANSI_N), flags: [.control, .command]))
        XCTAssertEqual(center.bindings[.openPanel]?.displayString, "⌃⌘N")
        XCTAssertTrue(fake.live.contains(HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | cmdKey))))

        center.beginRecording(.openPanel)
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_Delete), flags: []))
        XCTAssertNil(center.bindings[.openPanel], "Delete clears it")
        XCTAssertEqual(fake.live.count, 2)
    }

    func testTeardownLeavesNoMonitor() {
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        center.beginRecording(.translateClipboard)
        center.teardown()
        XCTAssertFalse(center.isListening)
    }

    func testNothingStoredMeansTheDefault() {
        for action in HotKeyAction.allCases {
            XCTAssertEqual(HotKeyBinding.stored(for: action, in: defaults), action.defaultBinding)
        }
    }

    /// A cleared shortcut must stay cleared across a relaunch. Stored as a
    /// missing key, it would read back as the default.
    func testAClearedShortcutStaysCleared() {
        HotKeyBinding.store(nil, for: .translateClipboard, in: defaults)
        XCTAssertNil(HotKeyBinding.stored(for: .translateClipboard, in: defaults))
    }

    func testAChosenShortcutRoundTrips() {
        let chosen = HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | cmdKey))
        HotKeyBinding.store(chosen, for: .openPanel, in: defaults)
        XCTAssertEqual(HotKeyBinding.stored(for: .openPanel, in: defaults), chosen)
        HotKeyBinding.store(HotKeyAction.openPanel.defaultBinding, for: .openPanel, in: defaults)
        XCTAssertNil(defaults.object(forKey: HotKeyAction.openPanel.defaultsKey), "the default is stored as nothing")
    }

    func testAReboundShortcutRegistersTheNewKeyAndDropsTheOld() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))
        XCTAssertEqual(fake.live.count, 3)

        let chosen = HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | cmdKey))
        center.setBinding(chosen, for: .openPanel)

        XCTAssertEqual(fake.live.count, 3)
        XCTAssertTrue(fake.live.contains(chosen))
        XCTAssertFalse(fake.live.contains(HotKeyAction.openPanel.defaultBinding))
    }

    /// Two actions on one key cannot both fire, so taking a key moves it.
    func testTakingAnotherActionsKeyClearsThatAction() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))

        center.setBinding(HotKeyAction.showLyrics.defaultBinding, for: .openPanel)

        XCTAssertEqual(center.bindings[.openPanel], HotKeyAction.showLyrics.defaultBinding)
        XCTAssertNil(center.bindings[.showLyrics])
        XCTAssertNil(HotKeyBinding.stored(for: .showLyrics, in: defaults))
        XCTAssertEqual(fake.live.count, 2)
    }

    /// Pressing the key already bound, to record it, must not fire it.
    func testRecordingLetsEveryShortcutGoUntilItEnds() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))

        center.beginRecording(.openPanel)
        XCTAssertTrue(fake.live.isEmpty)
        center.endRecording()
        XCTAssertEqual(fake.live.count, 3)
    }

    /// A combination macOS will not register comes back refused, and Settings
    /// has to be able to say which one.
    func testARefusedShortcutIsReported() {
        let fake = FakeRegistrar()
        fake.refuse = [HotKeyAction.translateClipboard.defaultBinding]
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))

        XCTAssertEqual(center.refused, [.translateClipboard])
    }

    func testRestoringTheDefaultsForgetsEveryChoice() {
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        center.setBinding(nil, for: .openPanel)
        center.restoreDefaults()
        XCTAssertEqual(center.bindings[.openPanel], HotKeyAction.openPanel.defaultBinding)
        XCTAssertNil(defaults.object(forKey: HotKeyAction.openPanel.defaultsKey))
    }
}

// MARK: - A shortcut taken from another action, and key names by layout

extension HotKeyTests {
    /// Recording a combination another action owns used to unbind that action
    /// silently, "Open the panel" included, which is the keyboard and
    /// VoiceOver way in.
    func testTakingAnotherActionsKeyIsReported() {
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        let taken = HotKeyAction.openPanel.defaultBinding
        center.setBinding(taken, for: .showLyrics)
        XCTAssertEqual(center.displaced?.binding, taken)
        XCTAssertEqual(center.displaced?.from, .openPanel)
        XCTAssertEqual(center.displaced?.to, .showLyrics)
        XCTAssertNil(center.bindings[.openPanel])

        center.beginRecording(.translateClipboard)
        XCTAssertNil(center.displaced, "the next recording clears the note")
        center.endRecording()

        center.setBinding(HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: HotKeyBinding.defaultModifiers), for: .showLyrics)
        XCTAssertNil(center.displaced, "a free combination displaces nothing")
    }

    func testRestoringDefaultsClearsTheDisplacedNote() {
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        center.setBinding(HotKeyAction.openPanel.defaultBinding, for: .showLyrics)
        center.restoreDefaults()
        XCTAssertNil(center.displaced)
    }

    private func layout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first
        else { throw XCTSkip("\(id) is not installed on this Mac") }
        return source
    }

    /// QWERTZ prints Z where the US key code for Y is. The old fixed US table
    /// made Settings and the welcome say one key while another fired.
    func testKeyNamesFollowTheGermanLayout() throws {
        let german = try layout("com.apple.keylayout.German")
        XCTAssertEqual(KeyboardLayoutNames.name(for: kVK_ANSI_Y, in: german), "Z")
        XCTAssertEqual(KeyboardLayoutNames.name(for: kVK_ANSI_Z, in: german), "Y")
        XCTAssertNil(KeyboardLayoutNames.name(for: kVK_LeftArrow, in: german), "arrows keep their glyph from the table")
        XCTAssertNil(KeyboardLayoutNames.name(for: kVK_Space, in: german))
    }

    /// A Cyrillic layout has no Latin letters, so the name comes from the
    /// ASCII-capable layout, the way macOS menus keep showing the Latin one.
    func testANonLatinLayoutFallsBackToLatin() throws {
        let russian = try layout("com.apple.keylayout.Russian")
        let name = KeyboardLayoutNames.name(for: kVK_ANSI_I, in: russian)
        XCTAssertEqual(name, KeyboardLayoutNames.name(for: kVK_ANSI_I))
        XCTAssertTrue(name?.unicodeScalars.allSatisfy { $0.value < 0x250 } ?? false, "got \(name ?? "nil")")
    }

    func testTheBindingUsesTheLayoutNameAndKeepsGlyphsForOtherKeys() {
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey)).displayString, "⌘←")
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)).displayString, "⌘F5")
        let name = KeyboardLayoutNames.name(for: kVK_ANSI_I)
        XCTAssertEqual(HotKeyBinding.keyName(UInt32(kVK_ANSI_I)), name ?? "I")
    }
}

// MARK: - The Prompter's two keys (spec 5.4, section 4, E-44, E-45)

extension HotKeyTests {
    private var core: [HotKeyAction] { [.openPanel, .showLyrics, .translateClipboard] }
    private var coreKeys: Set<HotKeyBinding> { Set(core.map(\.defaultBinding)) }
    private var prompterKeys: Set<HotKeyBinding> {
        [HotKeyAction.prompterToggle.defaultBinding, HotKeyAction.prompterStop.defaultBinding]
    }

    private func installed(_ fake: FakeRegistrar) -> HotKeyCenter {
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.refuseSound = {}
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))
        return center
    }

    /// The core three belong to no feature and are always available; the two
    /// new ones belong to the Prompter. Release 2's faster and slower keys do
    /// not exist yet.
    func testThePrompterActionsBelongToThePrompterAndNothingElseDoes() {
        XCTAssertEqual(HotKeyAction.allCases, [.openPanel, .showLyrics, .translateClipboard, .prompterToggle, .prompterStop])
        for action in core { XCTAssertNil(action.feature, "\(action)") }
        XCTAssertEqual(HotKeyAction.prompterToggle.feature, .prompter)
        XCTAssertEqual(HotKeyAction.prompterStop.feature, .prompter)
        XCTAssertEqual(HotKeyAction.prompterToggle.defaultsKey, "hotkey.prompterToggle")
        XCTAssertTrue(prompterKeys.isDisjoint(with: coreKeys), "⌃⌥⌘P and ⌃⌥⌘S take nothing from the first three")
    }

    /// An optional feature is off until someone says it is on. A center
    /// nobody told about the Prompter registers only the core three, which
    /// is also what every test written before the Prompter assumes.
    func testAPrompterKeyIsNotRegisteredUntilTheFeatureIsOn() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        XCTAssertEqual(fake.live, coreKeys)
        XCTAssertTrue(center.enabledFeatures.isEmpty)
        XCTAssertEqual(center.availableActions, core)
    }

    func testTheFeatureSwitchRegistersAndUnregistersLive() {
        let fake = FakeRegistrar()
        let center = installed(fake)

        center.setFeature(.prompter, enabled: true)
        XCTAssertEqual(fake.live, coreKeys.union(prompterKeys))
        XCTAssertTrue(center.isAvailable(.prompterToggle))

        center.setFeature(.prompter, enabled: false)
        XCTAssertEqual(fake.live, coreKeys)
        XCTAssertFalse(center.isAvailable(.prompterStop))
    }

    func testAPrompterKeyIsRebindableAndClearableWhileOn() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        center.setFeature(.prompter, enabled: true)

        center.beginRecording(.prompterToggle)
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .option, .command]))
        let chosen = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers)
        XCTAssertEqual(center.bindings[.prompterToggle], chosen)
        XCTAssertEqual(HotKeyBinding.stored(for: .prompterToggle, in: defaults), chosen)
        XCTAssertTrue(fake.live.contains(chosen))
        XCTAssertFalse(fake.live.contains(HotKeyAction.prompterToggle.defaultBinding))

        center.beginRecording(.prompterStop)
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_ForwardDelete), flags: []))
        XCTAssertNil(center.bindings[.prompterStop])
        XCTAssertNil(HotKeyBinding.stored(for: .prompterStop, in: defaults), "cleared stays cleared")
        XCTAssertEqual(fake.live, coreKeys.union([chosen]))
    }

    /// The same two-of-⌘⌃⌥ rule as the first three: plain Escape, or any
    /// single-modifier press, can never become a Prompter key (spec 5.4:
    /// plain Escape is never claimed).
    func testAPrompterKeyFollowsTheSameRules() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        center.setFeature(.prompter, enabled: true)
        center.beginRecording(.prompterStop)
        XCTAssertFalse(center.record(keyCode: UInt16(kVK_ANSI_S), flags: [.command]))
        XCTAssertTrue(center.record(keyCode: UInt16(kVK_Escape), flags: []), "Escape cancels the recording")
        XCTAssertEqual(center.bindings[.prompterStop], HotKeyAction.prompterStop.defaultBinding, "and is not recorded")
    }

    /// Taking a key from a Prompter action while on is reported, exactly as
    /// between the first three.
    func testTakingAPrompterKeyWhileOnIsReported() {
        let center = installed(FakeRegistrar())
        center.setFeature(.prompter, enabled: true)
        center.setBinding(HotKeyAction.prompterToggle.defaultBinding, for: .openPanel)
        XCTAssertEqual(center.displaced?.from, .prompterToggle)
        XCTAssertNil(center.bindings[.prompterToggle])
    }

    /// While off the Prompter's actions are absent, so a core action may take
    /// ⌃⌥⌘P without a note about an action the user cannot see, and without
    /// writing anything for the Prompter. When the switch comes back, the
    /// core action keeps the key and the Prompter's is reported as shadowed
    /// rather than registered twice (two non-exclusive Carbon registrations
    /// of one key would both fire).
    func testWhileOffACoreActionMayTakeAPrompterKey() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        let p = HotKeyAction.prompterToggle.defaultBinding

        center.setBinding(p, for: .openPanel)
        XCTAssertNil(center.displaced, "nothing visible lost its key")
        XCTAssertEqual(center.bindings[.prompterToggle], p)
        XCTAssertFalse(defaults.writes.contains(HotKeyAction.prompterToggle.defaultsKey))

        let before = fake.registrations
        center.setFeature(.prompter, enabled: true)
        XCTAssertEqual(center.shadowed, [.prompterToggle: .openPanel])
        XCTAssertTrue(fake.live.contains(p))
        XCTAssertEqual(fake.registrations - before, 4, "the three core keys and ⌃⌥⌘S: ⌃⌥⌘P once, not twice")
        XCTAssertEqual(fake.live, [p, HotKeyAction.showLyrics.defaultBinding,
                                   HotKeyAction.translateClipboard.defaultBinding, HotKeyAction.prompterStop.defaultBinding])

        // Ruling 20.6 #7d: Settings says so, or the row shows ⌃⌥⌘P bound to
        // a key that does nothing.
        let notes = SettingsPane.shadowedShortcutNotes(center)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first, localized(
            "%@ is already used by “%@”, so “%@” does nothing. Choose another shortcut.",
            p.displayString, HotKeyAction.openPanel.title, HotKeyAction.prompterToggle.title
        ))

        center.setBinding(HotKeyAction.openPanel.defaultBinding, for: .openPanel)
        XCTAssertTrue(center.shadowed.isEmpty, "the key is free again")
        XCTAssertTrue(SettingsPane.shadowedShortcutNotes(center).isEmpty, "and the note goes with it")
        XCTAssertEqual(fake.live, coreKeys.union(prompterKeys))
    }

    /// An absent action cannot be recorded, set or restored: Settings shows
    /// no row for it, and nothing else may write it behind the switch.
    func testAnAbsentActionCannotBeChanged() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        defaults.resetWrites()

        center.beginRecording(.prompterToggle)
        XCTAssertNil(center.recording)
        XCTAssertFalse(center.isListening)

        center.setBinding(nil, for: .prompterStop)
        XCTAssertEqual(center.bindings[.prompterStop], HotKeyAction.prompterStop.defaultBinding)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(fake.live, coreKeys)
    }

    /// Restore Default Shortcuts restores what Settings shows. While off that
    /// is the core three; the Prompter's choices wait, untouched, for the
    /// switch.
    func testRestoringDefaultsWhileOffLeavesThePrompterAlone() {
        let center = installed(FakeRegistrar())
        center.setFeature(.prompter, enabled: true)
        center.setBinding(nil, for: .prompterStop)
        center.setBinding(nil, for: .openPanel)
        center.setFeature(.prompter, enabled: false)
        defaults.resetWrites()

        center.restoreDefaults()

        XCTAssertEqual(center.bindings[.openPanel], HotKeyAction.openPanel.defaultBinding)
        XCTAssertNil(center.bindings[.prompterStop])
        XCTAssertFalse(defaults.writes.contains(HotKeyAction.prompterStop.defaultsKey))
    }

    func testRestoringDefaultsWhileOnRestoresThePrompterKeysToo() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        center.setFeature(.prompter, enabled: true)
        center.setBinding(nil, for: .prompterStop)

        center.restoreDefaults()

        XCTAssertEqual(center.bindings[.prompterStop], HotKeyAction.prompterStop.defaultBinding)
        XCTAssertEqual(fake.live, coreKeys.union(prompterKeys))
    }

    /// The switch going off in the middle of recording one of its keys ends
    /// the recording, so the monitor that swallows every key goes with it.
    func testTurningTheFeatureOffEndsARecordingOfItsKey() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        center.setFeature(.prompter, enabled: true)
        center.beginRecording(.prompterStop)
        XCTAssertTrue(fake.live.isEmpty)

        center.setFeature(.prompter, enabled: false)

        XCTAssertNil(center.recording)
        XCTAssertFalse(center.isListening)
        XCTAssertEqual(fake.live, coreKeys)
    }

    /// A recording of a core key is not the switch's business: it goes on,
    /// with everything still let go, and the new state applies when it ends.
    func testTheSwitchDoesNotEndARecordingOfACoreKey() {
        let fake = FakeRegistrar()
        let center = installed(fake)
        center.beginRecording(.openPanel)
        center.setFeature(.prompter, enabled: true)
        XCTAssertEqual(center.recording, .openPanel)
        XCTAssertTrue(fake.live.isEmpty, "recording lets every key go")
        center.endRecording()
        XCTAssertEqual(fake.live, coreKeys.union(prompterKeys))
    }

    /// A note about a Prompter key does not outlive the switch.
    func testTurningTheFeatureOffClearsANoteAboutItsKeys() {
        let center = installed(FakeRegistrar())
        center.setFeature(.prompter, enabled: true)
        center.setBinding(HotKeyAction.openPanel.defaultBinding, for: .prompterToggle)
        XCTAssertNotNil(center.displaced)
        center.setFeature(.prompter, enabled: false)
        XCTAssertNil(center.displaced)
    }
}

@MainActor
private final class FakeRegistrar {
    var live: Set<HotKeyBinding> = []
    var refuse: Set<HotKeyBinding> = []
    /// Every successful registration, counted, so a test can tell one
    /// registration of a key from two that `live` (a set) would merge.
    private(set) var registrations = 0

    final class Registration: HotKeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    func register(_ binding: HotKeyBinding, _ action: @escaping () -> Void) -> HotKeyRegistration? {
        guard !refuse.contains(binding) else { return nil }
        registrations += 1
        live.insert(binding)
        return Registration { [weak self] in self?.live.remove(binding) }
    }
}

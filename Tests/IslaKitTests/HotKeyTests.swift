import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// The shortcuts are the only way into a panel that never activates, so each
/// one has to be something no other app owns, and one the user can move when
/// it is taken anyway.
@MainActor
final class HotKeyTests: XCTestCase {
    /// A private suite per test, removed when the test ends, so no test
    /// writes a shortcut into the defaults of the machine running it.
    private lazy var defaults: UserDefaults = {
        let suite = "HotKeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }()

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
            // Finder's Move Item Here, the clipboard key's near neighbour.
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey)),
        ]
        for action in HotKeyAction.allCases {
            XCTAssertFalse(taken.contains(action.defaultBinding), "\(action) defaults to a key an app already owns")
            XCTAssertEqual(action.defaultBinding.modifiers, HotKeyBinding.defaultModifiers)
        }
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.defaultBinding)).count, HotKeyAction.allCases.count)
    }

    /// ⌃⌥⌘V is the fourth key (spec §19.8, §19.13): registered with the
    /// others, and pressing it runs the clipboard's handler and no other.
    func testTheClipboardKeyIsRegisteredAndRunsItsOwnHandler() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        var ran: [HotKeyAction] = []
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { action in (action, { ran.append(action) }) }))
        XCTAssertEqual(HotKeyAction.allCases, [.openPanel, .showClipboard, .showLyrics, .translateClipboard],
                       "the order Settings › Shortcuts lists them in")
        let v = HotKeyBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: HotKeyBinding.defaultModifiers)
        XCTAssertTrue(fake.live.contains(v))
        fake.press(v)
        XCTAssertEqual(ran, [.showClipboard])
        XCTAssertEqual(HotKeyAction.showClipboard.title, localized("Show the clipboard"))
    }

    func testTheDefaultsReadTheWayMacOSWritesThem() {
        XCTAssertEqual(HotKeyAction.openPanel.defaultBinding.displayString, "⌃⌥⌘I")
        XCTAssertEqual(HotKeyAction.showClipboard.defaultBinding.displayString, "⌃⌥⌘V")
        XCTAssertEqual(HotKeyAction.showLyrics.defaultBinding.displayString, "⌃⌥⌘L")
        XCTAssertEqual(HotKeyAction.translateClipboard.defaultBinding.displayString, "⌃⌥⌘T")
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
        XCTAssertEqual(fake.live.count, 3)
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
        XCTAssertEqual(fake.live.count, 4)

        let chosen = HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | cmdKey))
        center.setBinding(chosen, for: .openPanel)

        XCTAssertEqual(fake.live.count, 4)
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
        XCTAssertEqual(fake.live.count, 3)
    }

    /// Pressing the key already bound, to record it, must not fire it.
    func testRecordingLetsEveryShortcutGoUntilItEnds() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(defaults: defaults, registrar: fake.register)
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))

        center.beginRecording(.openPanel)
        XCTAssertTrue(fake.live.isEmpty)
        center.endRecording()
        XCTAssertEqual(fake.live.count, 4)
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

    /// A default that arrives with an update can land on a combination the
    /// user had already given another action — ⌃⌥⌘V came with R8. Their choice
    /// wins and Settings says so; two actions on one key could not both fire
    /// (R8 review F11). The default gives way for this launch only and is
    /// not stored as cleared, so it comes back once the user moves their own
    /// choice elsewhere (R-9).
    func testANewDefaultGivesWayToTheUsersOwnChoice() {
        let v = HotKeyAction.showClipboard.defaultBinding
        HotKeyBinding.store(v, for: .openPanel, in: defaults)
        let center = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        XCTAssertEqual(center.bindings[.openPanel], v, "the user's own choice stands")
        XCTAssertNil(center.bindings[.showClipboard], "the new default gives way")
        XCTAssertEqual(center.displaced, .init(binding: v, from: .showClipboard, to: .openPanel), "and Settings says so")
        XCTAssertNil(defaults.object(forKey: HotKeyAction.showClipboard.defaultsKey), "nothing is written for it")
        XCTAssertEqual(center.bindings[.showLyrics], HotKeyAction.showLyrics.defaultBinding, "the others are untouched")

        HotKeyBinding.store(nil, for: .openPanel, in: defaults)
        let later = HotKeyCenter(defaults: defaults, registrar: FakeRegistrar().register)
        XCTAssertEqual(later.bindings[.showClipboard], v, "with the clash gone, the default is back")
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

@MainActor
private final class FakeRegistrar {
    var live: Set<HotKeyBinding> = []
    var refuse: Set<HotKeyBinding> = []
    private var actions: [HotKeyBinding: () -> Void] = [:]

    /// The key pressed, as the system would deliver it: whatever is
    /// registered on it runs, and an unregistered key does nothing.
    func press(_ binding: HotKeyBinding) {
        guard live.contains(binding) else { return }
        actions[binding]?()
    }

    final class Registration: HotKeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    func register(_ binding: HotKeyBinding, _ action: @escaping () -> Void) -> HotKeyRegistration? {
        guard !refuse.contains(binding) else { return nil }
        live.insert(binding)
        actions[binding] = action
        return Registration { [weak self] in
            self?.live.remove(binding)
            self?.actions[binding] = nil
        }
    }
}

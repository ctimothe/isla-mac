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

@MainActor
private final class FakeRegistrar {
    var live: Set<HotKeyBinding> = []
    var refuse: Set<HotKeyBinding> = []

    final class Registration: HotKeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    func register(_ binding: HotKeyBinding, _ action: @escaping () -> Void) -> HotKeyRegistration? {
        guard !refuse.contains(binding) else { return nil }
        live.insert(binding)
        return Registration { [weak self] in self?.live.remove(binding) }
    }
}

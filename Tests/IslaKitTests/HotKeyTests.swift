import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// The shortcuts are the only way into a panel that never activates, so each
/// one has to be something no other app owns, and one the user can move when
/// it is taken anyway.
@MainActor
final class HotKeyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "HotKeyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

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

    /// A press with no ⌘, ⌃ or ⌥ would take a letter from every text field.
    func testAPressNeedsCommandControlOrOption() {
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: []))
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.shift]))
        XCTAssertNil(HotKeyBinding(keyCode: UInt16(kVK_Command), flags: [.command]), "a modifier alone is not a key")
        let recorded = HotKeyBinding(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .option, .shift])
        XCTAssertEqual(recorded?.displayString, "⌃⌥⇧K")
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

    /// A combination another app registered first comes back refused, and
    /// Settings has to be able to say which one.
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

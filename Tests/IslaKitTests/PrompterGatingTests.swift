import Carbon.HIToolbox
import Combine
import Foundation
import XCTest
@testable import IslaKit

// MARK: - Fakes
//
// Nothing here touches `UserDefaults.standard`, Application Support, a real
// timer, a real power assertion or a real Carbon hot key: a real one reserves
// the combination for the whole login session of the Mac running the tests.

/// A library file that fails the test the moment anything touches it. With
/// the switch off the library must not even be asked whether it exists.
private final class TrapFileIO: PrompterFileIO {
    func exists() -> Bool { XCTFail("the library was asked whether it exists while the switch is off"); return false }
    func read() throws -> Data { XCTFail("the library was read while the switch is off"); return Data() }
    func writeAtomically(_ data: Data) throws { XCTFail("the library was written while the switch is off") }
    func copyAside(as name: String) throws -> String { XCTFail("the library was copied while the switch is off"); return name }
}

/// A library file that only counts.
private final class CountingFileIO: PrompterFileIO {
    private(set) var existsCalls = 0
    private(set) var reads = 0
    private(set) var writes = 0
    func exists() -> Bool { existsCalls += 1; return false }
    func read() throws -> Data { reads += 1; throw CocoaError(.fileReadNoSuchFile) }
    func writeAtomically(_ data: Data) throws { writes += 1 }
    func copyAside(as name: String) throws -> String { name }
}

/// Counts every timer asked for and keeps them so a test can see whether
/// they were cancelled. Never fires anything by itself.
@MainActor
private final class CountingScheduler: PrompterScheduling {
    final class Entry: PrompterCancellable {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }
    private(set) var entries: [Entry] = []
    var live: [Entry] { entries.filter { !$0.isCancelled } }

    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry()
        entries.append(entry)
        return entry
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry()
        entries.append(entry)
        return entry
    }
}

@MainActor
private final class CountingKeepAwake: PrompterKeepAwake {
    private(set) var begins = 0
    private(set) var ends = 0
    func begin() { begins += 1 }
    func end() { ends += 1 }
}

@MainActor
private final class GatingRegistrar {
    var live: Set<HotKeyBinding> = []

    final class Registration: HotKeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    func register(_ binding: HotKeyBinding, _ action: @escaping () -> Void) -> HotKeyRegistration? {
        live.insert(binding)
        return Registration { [weak self] in self?.live.remove(binding) }
    }
}

// MARK: - Tests

/// Spec section 4: with the switch off the Prompter is absent, not hidden. No
/// tab, no hot key, no library read, no engine, timer or observer, and no
/// `prompter.*` default written except the switch itself. Turning the switch
/// on and off while the app runs registers and unregisters the hot keys, and
/// turning it off during a session stops the session first (E-44, E-45).
///
/// The tab itself is T5's; the predicate it will read is `isEnabled`, and
/// everything the tab would show lives in `parts`, which is nil while off.
@MainActor
final class PrompterGatingTests: XCTestCase {
    private var defaults = InMemoryDefaults()
    private var scheduler = CountingScheduler()
    private var keepAwake = CountingKeepAwake()
    private var built = 0

    private let coreDefaults: Set<HotKeyBinding> = [
        HotKeyAction.openPanel.defaultBinding,
        HotKeyAction.showLyrics.defaultBinding,
        HotKeyAction.translateClipboard.defaultBinding,
    ]

    /// A feature whose parts are built from `io`, counted, and wired to the
    /// fakes above, so whatever the feature builds can be seen.
    private func makeFeature(io: PrompterFileIO) -> PrompterFeature {
        PrompterFeature(defaults: defaults) { [unowned self] defaults in
            self.built += 1
            return PrompterParts(
                settings: PrompterSettings(defaults: defaults),
                library: PrompterLibrary(io: io, scheduler: self.scheduler),
                session: PrompterSession(now: { 0 }, scheduler: self.scheduler, keepAwake: self.keepAwake)
            )
        }
    }

    private func makeCenter(_ registrar: GatingRegistrar) -> HotKeyCenter {
        let center = HotKeyCenter(defaults: defaults, registrar: registrar.register)
        center.refuseSound = {}
        center.install(Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, {}) }))
        return center
    }

    /// What `AppDelegate` does: the center learns the switch's state before
    /// anything registers, then follows it live.
    private func wire(_ feature: PrompterFeature, to center: HotKeyCenter) -> AnyCancellable {
        center.setFeature(.prompter, enabled: feature.isEnabled)
        return feature.onChange { enabled in center.setFeature(.prompter, enabled: enabled) }
    }

    private var prompterWrites: [String] { defaults.writes.filter { $0.hasPrefix("prompter.") } }

    // MARK: Off is absent

    func testTheSwitchIsOffByDefaultAndNothingIsBuilt() {
        let feature = makeFeature(io: TrapFileIO())
        XCTAssertFalse(feature.isEnabled, "the predicate the tab, the rail and Settings read")
        XCTAssertNil(feature.parts, "no settings object, library or session exists while off")
        XCTAssertEqual(built, 0)
        XCTAssertTrue(scheduler.entries.isEmpty, "no timer")
        XCTAssertEqual(keepAwake.begins, 0, "no power assertion")
        XCTAssertTrue(defaults.writes.isEmpty, "not even the switch is written by reading it")
    }

    /// The trap fails the test on any touch. A feature that built its parts
    /// eagerly would ask the library whether it exists.
    func testOffReadsNoLibrary() {
        let feature = makeFeature(io: TrapFileIO())
        feature.set(false)
        XCTAssertNil(feature.parts)
        XCTAssertEqual(built, 0)
    }

    func testOffRegistersNoPrompterHotKey() {
        let registrar = GatingRegistrar()
        let center = makeCenter(registrar)
        let feature = makeFeature(io: TrapFileIO())
        let token = wire(feature, to: center)
        defer { token.cancel() }

        XCTAssertEqual(registrar.live, coreDefaults, "⌃⌥⌘P and ⌃⌥⌘S stay free for other apps (E-44)")
        XCTAssertFalse(center.isAvailable(.prompterToggle))
        XCTAssertFalse(center.isAvailable(.prompterStop))
        XCTAssertEqual(center.availableActions, [.openPanel, .showLyrics, .translateClipboard])
    }

    /// A binding stored while the feature was on (or a hand-edited one, or
    /// garbage) survives in the plist after the switch goes off. It must
    /// register nothing and crash nothing.
    func testAStaleStoredPrompterBindingRegistersNothingWhileOff() {
        let chosen = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | cmdKey))
        HotKeyBinding.store(chosen, for: .prompterToggle, in: defaults)
        defaults.set(["keyCode": "P"], forKey: HotKeyAction.prompterStop.defaultsKey)
        defaults.resetWrites()

        let registrar = GatingRegistrar()
        let center = makeCenter(registrar)
        let feature = makeFeature(io: TrapFileIO())
        let token = wire(feature, to: center)
        defer { token.cancel() }

        XCTAssertEqual(center.bindings[.prompterToggle], chosen, "kept for when the switch comes back")
        XCTAssertEqual(registrar.live, coreDefaults)
        XCTAssertTrue(center.refused.isEmpty, "an absent action is not a refused one")
        XCTAssertTrue(defaults.writes.isEmpty, "nothing rewrote the stale binding")
    }

    /// The whole off path, launch to quit as far as T4 reaches: read the
    /// switch, build the hot keys, restore the default shortcuts. Not one
    /// `prompter.*` key is written.
    func testOffWritesNoPrompterKey() {
        let registrar = GatingRegistrar()
        let center = makeCenter(registrar)
        let feature = makeFeature(io: TrapFileIO())
        let token = wire(feature, to: center)
        defer { token.cancel() }
        center.restoreDefaults()
        feature.set(false)

        XCTAssertTrue(prompterWrites.isEmpty, "wrote \(prompterWrites)")
        XCTAssertFalse(defaults.writes.contains { $0.contains("prompter") }, "nor a hot key of the prompter's: \(defaults.writes)")
    }

    /// Handlers run in the order they were added, every time, and a
    /// cancelled one is not called again. The first version delivered through
    /// a Combine subject, whose order is unspecified, and this file's
    /// switch-off test failed on one run in two.
    func testHandlersRunInTheOrderTheyWereAddedAndStopWhenCancelled() {
        let feature = makeFeature(io: CountingFileIO())
        var log: [String] = []
        let tokens = (0..<8).map { index in feature.onChange { log.append("\(index) \($0)") } }
        feature.set(true)
        XCTAssertEqual(log, (0..<8).map { "\($0) true" })
        log.removeAll()
        tokens[3].cancel()
        feature.set(false)
        XCTAssertEqual(log, [0, 1, 2, 4, 5, 6, 7].map { "\($0) false" })
        tokens.forEach { $0.cancel() }
    }

    /// A value of the wrong type is not an "on": the safe reading of a
    /// switch nobody set properly is off.
    func testASwitchOfTheWrongTypeReadsOff() {
        for bad: Any in ["YES", 1, 1.0, ["on"]] {
            defaults = InMemoryDefaults([PrompterFeature.enabledKey: bad])
            let feature = makeFeature(io: TrapFileIO())
            XCTAssertFalse(feature.isEnabled, "\(bad)")
            XCTAssertNil(feature.parts)
        }
    }

    // MARK: On

    func testTurningOnBuildsThePartsAndReadsTheLibraryOnceButStartsNothing() {
        let io = CountingFileIO()
        let feature = makeFeature(io: io)
        var heard: [Bool] = []
        let token = feature.onChange { heard.append($0) }
        defer { token.cancel() }

        feature.set(true)

        XCTAssertTrue(feature.isEnabled)
        XCTAssertNotNil(feature.parts)
        XCTAssertEqual(built, 1)
        XCTAssertEqual(io.existsCalls, 1, "the library is loaded once, so the tab has scripts to show")
        XCTAssertEqual(feature.parts?.library.status, .ready)
        XCTAssertEqual(io.writes, 0, "a missing library is not created by turning the switch on (E-53)")
        XCTAssertTrue(scheduler.entries.isEmpty, "no timer until a session starts")
        XCTAssertEqual(keepAwake.begins, 0)
        XCTAssertEqual(feature.parts?.session.state, .idle)
        XCTAssertEqual(heard, [true])
        XCTAssertEqual(prompterWrites, [PrompterFeature.enabledKey], "the switch, and only the switch")
        XCTAssertEqual(defaults.storage[PrompterFeature.enabledKey] as? Bool, true)
    }

    /// The switch read at launch: on means the parts exist from the start.
    func testAStoredOnBuildsThePartsAtLaunch() {
        defaults = InMemoryDefaults([PrompterFeature.enabledKey: true])
        let io = CountingFileIO()
        let feature = makeFeature(io: io)
        XCTAssertTrue(feature.isEnabled)
        XCTAssertNotNil(feature.parts)
        XCTAssertEqual(io.existsCalls, 1)
        XCTAssertTrue(defaults.writes.isEmpty, "reading the switch writes nothing")
    }

    func testSettingTheSameValueDoesNothing() {
        let feature = makeFeature(io: TrapFileIO())
        var heard = 0
        let token = feature.onChange { _ in heard += 1 }
        defer { token.cancel() }
        feature.set(false)
        XCTAssertEqual(heard, 0)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    // MARK: Live switching

    func testTurningTheSwitchOnAndOffRegistersAndUnregistersThePrompterKeysLive() {
        let registrar = GatingRegistrar()
        let center = makeCenter(registrar)
        let feature = makeFeature(io: CountingFileIO())
        let token = wire(feature, to: center)
        defer { token.cancel() }
        let prompterKeys: Set<HotKeyBinding> = [
            HotKeyAction.prompterToggle.defaultBinding, HotKeyAction.prompterStop.defaultBinding,
        ]

        feature.set(true)
        XCTAssertEqual(registrar.live, coreDefaults.union(prompterKeys))
        XCTAssertEqual(center.availableActions.count, 5)

        feature.set(false)
        XCTAssertEqual(registrar.live, coreDefaults, "a key bound while off is free for other apps")

        feature.set(true)
        XCTAssertEqual(registrar.live, coreDefaults.union(prompterKeys), "and comes back with the switch")
    }

    /// E-45 and the Switch-off row of 7.1: the session ends first, through the
    /// same path as Stop, while every part still exists; only then do the
    /// surfaces and the hot keys go.
    func testTurningOffDuringASessionStopsTheSessionFirst() throws {
        let registrar = GatingRegistrar()
        let center = makeCenter(registrar)
        let feature = makeFeature(io: CountingFileIO())
        var log: [String] = []
        feature.endSession = { session in
            log.append("stop while \(session.state) enabled=\(feature.isEnabled) parts=\(feature.parts != nil)")
            session.stop()
        }
        let hotKeys = wire(feature, to: center)
        let listener = feature.onChange { enabled in
            log.append("changed \(enabled) live=\(registrar.live.count)")
        }
        defer { hotKeys.cancel(); listener.cancel() }

        feature.set(true)
        log.removeAll()
        let parts = try XCTUnwrap(feature.parts)
        XCTAssertTrue(parts.session.start(pages: [PromptScript("one two three four")]))
        XCTAssertEqual(parts.session.state, .running)
        XCTAssertFalse(scheduler.live.isEmpty, "a running session ticks")
        XCTAssertEqual(keepAwake.begins, 1)

        feature.set(false)

        XCTAssertEqual(log, [
            "stop while running enabled=true parts=true",
            "changed false live=3",
        ])
        XCTAssertEqual(parts.session.state, .ended)
        XCTAssertTrue(scheduler.live.isEmpty, "no timer outlives the switch")
        XCTAssertEqual(keepAwake.ends, keepAwake.begins, "the display may sleep again")
        XCTAssertNil(feature.parts)
    }

    /// The controller's Stop path (T6) replaces the hook. If that path ever
    /// fails to end the session, the switch still does: no session survives
    /// the feature it belongs to.
    func testTurningOffEndsTheSessionEvenWhenTheHookDoesNot() throws {
        let feature = makeFeature(io: CountingFileIO())
        var called = 0
        feature.endSession = { _ in called += 1 }
        feature.set(true)
        let session = try XCTUnwrap(feature.parts?.session)
        session.start(pages: [PromptScript("hello there")])

        feature.set(false)

        XCTAssertEqual(called, 1)
        XCTAssertEqual(session.state, .ended)
        XCTAssertTrue(scheduler.live.isEmpty)
    }

    /// No live session: the hook is not asked to stop anything.
    func testTurningOffWithNoSessionDoesNotCallTheStopHook() {
        let feature = makeFeature(io: CountingFileIO())
        var called = 0
        feature.endSession = { _ in called += 1 }
        feature.set(true)
        feature.set(false)
        XCTAssertEqual(called, 0)
    }

    /// Spec 12.1: the library is flushed when the switch turns off, so an
    /// edit made a moment before is on disk; scripts stay across off and on.
    func testTurningOffFlushesThePendingEdit() throws {
        let io = CountingFileIO()
        let feature = makeFeature(io: io)
        feature.set(true)
        let library = try XCTUnwrap(feature.parts?.library)
        _ = try library.addScript(title: "Talk", pages: ["Hello"])
        XCTAssertEqual(io.writes, 0, "debounced, not yet written")

        feature.set(false)

        XCTAssertEqual(io.writes, 1)
        XCTAssertTrue(scheduler.live.isEmpty, "the debounce timer went with the flush")
    }

    /// Off then on builds a fresh set of parts that reads the library again;
    /// nothing from the first set is kept alive by the feature.
    func testOffThenOnBuildsFreshParts() throws {
        let io = CountingFileIO()
        let feature = makeFeature(io: io)
        feature.set(true)
        weak let first = feature.parts?.session
        feature.set(false)
        XCTAssertNil(first, "the feature let go of the old session")
        feature.set(true)
        XCTAssertEqual(built, 2)
        XCTAssertEqual(io.existsCalls, 2)
        XCTAssertEqual(prompterWrites, Array(repeating: PrompterFeature.enabledKey, count: 3))
    }
}

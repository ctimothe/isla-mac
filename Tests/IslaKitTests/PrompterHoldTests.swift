import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import XCTest
@testable import IslaKit

// MARK: - Fakes
//
// Nothing here reaches `UserDefaults.standard`, the general pasteboard,
// Application Support, a real timer, a real power assertion or a real hot key.
// The view model's stores are built the way the accessibility probe builds
// them: a throwaway defaults suite, a private pasteboard and a temporary
// folder, all removed when the test ends.

@MainActor
private final class HoldTime {
    var now: TimeInterval = 5_000
}

/// Fires only when the test advances time, and keeps cancelled entries so a
/// test can run one anyway: the stale-closure race of spec 7.2.
@MainActor
private final class HoldScheduler: PrompterScheduling {
    final class Entry: PrompterCancellable {
        let interval: TimeInterval?
        var due: TimeInterval
        let action: @MainActor () -> Void
        private(set) var isCancelled = false

        init(interval: TimeInterval?, due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.due = due
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    let time: HoldTime
    private(set) var entries: [Entry] = []

    init(time: HoldTime) { self.time = time }

    var live: [Entry] { entries.filter { !$0.isCancelled } }
    var liveRepeating: [Entry] { live.filter { $0.interval != nil } }

    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: interval, due: time.now + interval, action: action)
        entries.append(entry)
        return entry
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: nil, due: time.now + max(0, delay), action: action)
        entries.append(entry)
        return entry
    }

    func advance(by dt: TimeInterval) {
        let target = time.now + dt
        while let entry = live.filter({ $0.due <= target + 1e-9 }).min(by: { $0.due < $1.due }) {
            time.now = max(time.now, entry.due)
            if let interval = entry.interval { entry.due += interval } else { entry.cancel() }
            entry.action()
        }
        time.now = target
    }
}

/// The display-awake assertion, counted. An unbalanced call is the bug
/// whatever the totals say.
@MainActor
private final class HoldLease: PrompterKeepAwake {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var unbalanced = false
    var isHeld: Bool { begins > ends }

    func begin() {
        if isHeld { unbalanced = true }
        begins += 1
    }

    func end() {
        if !isHeld { unbalanced = true; return }
        ends += 1
    }
}

/// An empty library file that remembers what was written to it.
private final class HoldFileIO: PrompterFileIO {
    private(set) var writes = 0
    func exists() -> Bool { false }
    func read() throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    func writeAtomically(_ data: Data) throws { writes += 1 }
    func copyAside(as name: String) throws -> String { name }
}

/// The controller's half of a start, as the view model sees it: whether the
/// screens are dark, whether a display is shared, and what the panel was
/// asked to do.
@MainActor
private final class HoldPanel {
    var screensAsleep = false
    var share: PrompterDisplayShare?
    private(set) var presented: [PrompterPresentation] = []
    private(set) var shareChecks = 0

    var hooks: PrompterPanelHooks {
        PrompterPanelHooks(
            screensAsleep: { [unowned self] in self.screensAsleep },
            displayShare: { [unowned self] in
                self.shareChecks += 1
                return self.share
            },
            present: { [unowned self] in self.presented.append($0) }
        )
    }
}

// MARK: - Tests

/// Spec 11 (panel integration) and the session-and-panel rows of section 16:
/// the panel's hold is `isPinnedOpen || session.holdsPanel`, and the two are
/// separate flags, so nothing that ends a pin ends a session and a session
/// never lengthens a pin. Lock and sleep pause and never resume; a display
/// change rebuilds the panel and leaves the session alone; every start is a
/// commanded open; a shared display asks first; the display-awake lease
/// follows the session on every path; and plain Escape is never claimed.
///
/// Everything is driven through the view model, which is where the controller
/// sends every Prompter command, with the controller's effects recorded by
/// `HoldPanel`. The controller's own guards are thin calls into what is
/// tested here (`canFoldOnRequest`, `endPin()`, `rebuildReopens`).
@MainActor
final class PrompterHoldTests: XCTestCase {
    private var time: HoldTime!
    private var scheduler: HoldScheduler!
    private var lease: HoldLease!
    private var defaults: InMemoryDefaults!
    private var panel: HoldPanel!
    private var firstRunAnswers = 0

    override func setUp() {
        super.setUp()
        time = HoldTime()
        scheduler = HoldScheduler(time: time)
        lease = HoldLease()
        defaults = InMemoryDefaults()
        panel = HoldPanel()
        firstRunAnswers = 0
    }

    // MARK: Builders

    private func makeFeature(enabled: Bool = true) -> PrompterFeature {
        if enabled { defaults.set(true, forKey: PrompterFeature.enabledKey) }
        return PrompterFeature(defaults: defaults) { [unowned self] defaults in
            PrompterParts(
                settings: PrompterSettings(defaults: defaults),
                library: PrompterLibrary(io: HoldFileIO(), scheduler: self.scheduler),
                session: PrompterSession(
                    now: { [unowned self] in self.time.now },
                    scheduler: self.scheduler,
                    keepAwake: self.lease
                )
            )
        }
    }

    /// A view model on isolated stores, wired to `feature` the way `build()`
    /// wires the controller's.
    private func makeModel(_ feature: PrompterFeature) throws -> NotchViewModel {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrompterHoldTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "com.ctimothe.isla.prompterhold.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ctimothe.isla.prompterhold.\(UUID().uuidString)"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
            UserDefaults().removePersistentDomain(forName: suiteName)
            pasteboard.releaseGlobally()
        }
        let clipboard = ClipboardStore(pasteboard: pasteboard)
        clipboard.wantsImages = { false }
        let stores = NotchStores(
            lyricsEnabled: { false },
            localLyricsDirectory: temp.appendingPathComponent("lyrics", isDirectory: true),
            shelf: ShelfStore(defaults: suite),
            clipboard: clipboard,
            screenshotVault: ScreenshotVault(paths: AppPaths(
                supportDirectory: temp.appendingPathComponent("support", isDirectory: true),
                screenshotDirectory: temp.appendingPathComponent("pictures", isDirectory: true)
            )),
            translator: Translator(defaults: suite, preferredLanguages: ["en"]),
            privacy: PrivacyMode(defaults: suite)
        )
        stores.media.isolateFromPlayers()
        let vm = NotchViewModel(geometry: geometry, stores: stores, prompterEnabled: feature.isEnabled)
        vm.recordFirstRunAnswered = { [unowned self] in self.firstRunAnswers += 1 }
        vm.prompterHooks = panel.hooks
        vm.attachPrompter(feature.parts)
        return vm
    }

    /// One script, made current, with a page that has words to read.
    @discardableResult
    private func addScript(
        to feature: PrompterFeature,
        pages: [String] = ["Hello there, everyone. [smile] Thank you for coming today."]
    ) throws -> UUID {
        let library = try XCTUnwrap(feature.parts?.library)
        let id = try library.addScript(title: "Talk", pages: pages)
        library.setCurrentScript(id)
        return id
    }

    private func session(_ feature: PrompterFeature) throws -> PrompterSession {
        try XCTUnwrap(feature.parts?.session)
    }

    /// Runs the clock until the page's last word is behind it.
    private func readToTheEnd() {
        for _ in 0..<400 { scheduler.advance(by: 0.05) }
    }

    // MARK: Hold

    /// 11.1: the session holds the panel while running, paused and finished,
    /// and lets it go the moment it stops.
    func testTheSessionHoldsThePanelWhileRunningPausedOrFinishedAndNotAfterStop() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        XCTAssertFalse(vm.holdsOpen, "nothing holds a panel before a session")
        vm.togglePrompter()
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(vm.holdsOpen)
        XCTAssertFalse(vm.isPinnedOpen, "the hold is the session's own, not a pin")

        session.pause(.user)
        XCTAssertTrue(vm.holdsOpen, "paused by the user")
        session.pause(.lock)
        session.resume()
        session.handle(.screenLocked)
        XCTAssertEqual(session.state, .paused(.lock))
        XCTAssertTrue(vm.holdsOpen, "paused for the lock")
        session.resume()
        readToTheEnd()
        XCTAssertEqual(session.state, .finished)
        XCTAssertTrue(vm.holdsOpen, "finished, waiting for the speaker")

        vm.stopPrompter()
        XCTAssertEqual(session.state, .ended)
        XCTAssertFalse(vm.holdsOpen, "Stop lets the panel go")
        XCTAssertEqual(panel.presented.last, .release, "and hands it back to the pointer")
    }

    /// E-42: the pointer leaving the panel does not fold it while a session
    /// runs, and folds it again once the session has stopped.
    func testThePointerLeavingDoesNotEndASession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()

        XCTAssertEqual(vm.pointerCrossed(inside: false), .standsAsItIs)
        XCTAssertEqual(try session(feature).state, .running)

        vm.stopPrompter()
        XCTAssertEqual(vm.pointerCrossed(inside: false), .closes, "the hold went with the session")
    }

    /// E-41 and 11.1: a click in another app and another app coming to the
    /// front end a pin. With a session live they end the pin and nothing else:
    /// the panel stays (`endPin()` says not to fold) and the session runs on.
    func testAnOutsideClickOrAnotherAppEndsOnlyThePin() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()
        // A pin made while the session runs: VoiceOver's click on the island.
        vm.isPinnedOpen = true

        XCTAssertTrue(vm.appActivated(ownPID: 1, activatedPID: 2), "another app still ends the pin")
        XCTAssertFalse(vm.endPin(), "but the panel must not fold under a session")
        XCTAssertFalse(vm.isPinnedOpen)
        XCTAssertTrue(vm.holdsOpen)
        XCTAssertEqual(try session(feature).state, .running)

        // Without a session the same end of a pin folds the panel, as before.
        vm.stopPrompter()
        vm.isPinnedOpen = true
        XCTAssertTrue(vm.endPin())
    }

    /// 11.1 and E-47: a Space change (Mission Control, a full-screen Keynote)
    /// folds an ordinary open panel and never a session's.
    func testASpaceChangeDoesNotFoldASession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        XCTAssertTrue(vm.canFoldOnRequest, "an ordinary panel folds on a Space change")

        vm.togglePrompter()
        XCTAssertFalse(vm.canFoldOnRequest, "not with a session on it")
        XCTAssertEqual(try session(feature).state, .running)

        vm.stopPrompter()
        XCTAssertTrue(vm.canFoldOnRequest)
    }

    /// 11.1: ending a pin, by any of its own routes, cannot end a session.
    func testEndingAPinDoesNotEndASession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()
        vm.isPinnedOpen = true

        vm.pointerArrived()
        XCTAssertFalse(vm.isPinnedOpen, "the pointer arriving ends the pin")
        XCTAssertEqual(try session(feature).state, .running, "and nothing else")
        XCTAssertTrue(vm.holdsOpen)
    }

    /// 11.1: a session does not lengthen a pin. A pin standing when a session
    /// starts is replaced by the session's own hold (so it cannot outlive the
    /// session and keep a pinned panel over a slideshow after Stop), and a pin
    /// made during a session still ends on its own events.
    func testASessionDoesNotExtendAPin() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.isPinnedOpen = true // ⌃⌥⌘I first

        vm.togglePrompter()
        XCTAssertFalse(vm.isPinnedOpen, "the session's hold replaces the pin")

        vm.isPinnedOpen = true
        XCTAssertTrue(vm.appActivated(ownPID: 1, activatedPID: 2))
        _ = vm.endPin()
        XCTAssertFalse(vm.isPinnedOpen, "the pin ended on its own event during the session")

        vm.stopPrompter()
        XCTAssertFalse(vm.isPinnedOpen, "and did not come back with the end of the session")
        XCTAssertFalse(vm.holdsOpen)
    }

    /// Ruling 20.6 #3. The scenario the review found: a Keynote talk, a
    /// session running, ⌃⌥⌘L (which pinned unconditionally), then ⌃⌥⌘S. The
    /// pin survived Stop and claimed plain Escape, so the next Escape folded
    /// Isla instead of ending the slideshow. Nothing pins while a session
    /// holds the panel: not the lyrics key, not ⌃⌥⌘I reopening a panel the
    /// lock folded, not a click from VoiceOver.
    func testNothingPinsThePanelWhileASessionHoldsIt() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()

        vm.setPinned(true)
        XCTAssertFalse(vm.isPinnedOpen, "⌃⌥⌘L and ⌃⌥⌘I pin through here; the session already holds the panel")
        vm.clickOpened(pointerIsOnPanel: false)
        XCTAssertFalse(vm.isPinnedOpen, "VoiceOver's click on the island does not pin either")
        try session(feature).handle(.screenLocked)
        vm.setPinned(true)
        XCTAssertFalse(vm.isPinnedOpen, "the lock folded the panel; reopening it on the paused session still does not pin")
        XCTAssertTrue(vm.holdsOpen, "the session holds it instead")

        vm.stopPrompter()
        vm.setPinned(true)
        XCTAssertTrue(vm.isPinnedOpen, "without a session a command pins as before")
        vm.setPinned(false)
        XCTAssertFalse(vm.isPinnedOpen)
    }

    /// And a pin that stands anyway (one made before this rule, a path not yet
    /// routed through it) is cleared by Stop, so Escape goes back to the app
    /// in front the moment the session ends.
    func testStopClearsAPinSoEscapeGoesBackToTheAppInFront() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()
        vm.isPinnedOpen = true

        vm.stopPrompter()
        XCTAssertFalse(vm.isPinnedOpen)
        XCTAssertFalse(NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false,
            locked: vm.isLockedPresentation, sessionHoldsPanel: vm.prompterHoldsPanel
        ), "Escape after Stop ends the slideshow, not Isla")
    }

    /// Ruling 20.6 #6. The I-beam rectangle is the editor's; when the stage
    /// replaced the tab (Start, or ⌃⌥⌘P from Translate) the last rectangle
    /// stayed, and the stage showed a text cursor over words nobody types in.
    func testAStartTakesTheEditorsIBeamAway() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let editor = CGRect(x: 40, y: 60, width: 300, height: 80)

        vm.chooseTab(.translate)
        vm.textInputRect = editor
        vm.togglePrompter()
        XCTAssertEqual(vm.textInputRect, .zero, "⌃⌥⌘P from Translate")
        vm.stopPrompter()

        vm.chooseTab(.prompter)
        vm.textInputRect = editor
        vm.startPrompter()
        XCTAssertEqual(vm.textInputRect, .zero, "Start from the tab")
    }

    /// Ruling 20.6 #7b (20.3 #6): system sleep folds the panel as the lock and
    /// display sleep do. It only paused before, so a lid shut on an external
    /// display woke to the stage still open.
    func testEverySleepAndTheLockFoldThePanelAndNothingElseDoes() {
        XCTAssertTrue(PrompterSystemEvent.screenLocked.foldsPanel)
        XCTAssertTrue(PrompterSystemEvent.displaysSlept.foldsPanel)
        XCTAssertTrue(PrompterSystemEvent.systemWillSleep.foldsPanel)
        for event in [PrompterSystemEvent.screenUnlocked, .woke, .screenParametersChanged, .appWillTerminate] {
            XCTAssertFalse(event.foldsPanel, "\(event)")
        }
    }

    // MARK: Lock and sleep

    /// 11.3, E-39: a lock pauses with the lock's reason, and unlocking leaves
    /// the session paused for the user to resume.
    func testALockPausesAndUnlockingDoesNotResume() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)
        vm.togglePrompter()

        session.handle(.screenLocked)
        XCTAssertEqual(session.state, .paused(.lock))
        session.handle(.screenUnlocked)
        session.handle(.woke)
        XCTAssertEqual(session.state, .paused(.lock), "never resumed by the system")
        let progress = session.progress
        scheduler.advance(by: 5)
        XCTAssertEqual(session.progress, progress, "and the text does not move behind the shield")
    }

    /// 11.3, E-40: display sleep and system sleep pause with the sleep reason;
    /// waking leaves the session paused.
    func testSleepPausesAndWakingDoesNotResume() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.togglePrompter()
        session.handle(.displaysSlept)
        XCTAssertEqual(session.state, .paused(.sleep))
        session.handle(.woke)
        XCTAssertEqual(session.state, .paused(.sleep))

        session.resume()
        session.handle(.systemWillSleep)
        XCTAssertEqual(session.state, .paused(.sleep), "system sleep is the same pause")
        session.handle(.woke)
        XCTAssertEqual(session.state, .paused(.sleep))

        // A lock after a sleep keeps the first reason (ruling 20.2 #6).
        session.handle(.screenLocked)
        XCTAssertEqual(session.state, .paused(.sleep))
    }

    // MARK: Display change

    /// 7.3, 11.4, E-38: a display change rebuilds the panel and its view model;
    /// the session, its clock, its timers and its lease carry on untouched, and
    /// the rebuilt panel reopens on it.
    func testADisplayChangeKeepsTheSession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        var first: NotchViewModel? = try makeModel(feature)
        let session = try session(feature)
        first?.togglePrompter()
        scheduler.advance(by: 0.5)

        let generation = session.generation
        let progress = session.progress
        let tickers = scheduler.liveRepeating.count
        let leaseCounts = (lease.begins, lease.ends)

        // What `rebuild()` does: the old model goes, a new one is built on
        // the same stores and handed the same parts.
        session.handle(.screenParametersChanged)
        first = nil
        let rebuilt = try makeModel(feature)

        XCTAssertTrue(rebuilt.prompterSession === session, "the same session, not a copy")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.generation, generation, "no new run")
        XCTAssertEqual(session.progress, progress)
        XCTAssertEqual(scheduler.liveRepeating.count, tickers, "one clock, still ticking")
        XCTAssertEqual(lease.begins, leaseCounts.0)
        XCTAssertEqual(lease.ends, leaseCounts.1, "the lease is not dropped and retaken")
        XCTAssertTrue(rebuilt.holdsOpen)

        scheduler.advance(by: 0.5)
        XCTAssertGreaterThan(session.progress, progress, "and the text keeps moving")

        XCTAssertTrue(NotchController.rebuildReopens(
            screensAsleep: false, pointerOnTarget: false, wasOpen: true, pointerOnBody: false,
            sessionHoldsPanel: true
        ), "a panel open on a session reopens wherever the pointer is")
        XCTAssertFalse(NotchController.rebuildReopens(
            screensAsleep: false, pointerOnTarget: false, wasOpen: false, pointerOnBody: false,
            sessionHoldsPanel: true
        ), "a panel that was shut stays shut")
        XCTAssertFalse(NotchController.rebuildReopens(
            screensAsleep: true, pointerOnTarget: true, wasOpen: true, pointerOnBody: true,
            sessionHoldsPanel: true
        ), "and nothing opens on a dark display")
        XCTAssertFalse(NotchController.rebuildReopens(
            screensAsleep: false, pointerOnTarget: false, wasOpen: true, pointerOnBody: false,
            sessionHoldsPanel: false
        ), "without a session the pointer decides, as before")
    }

    // MARK: Commanded open

    /// 5.4, 11.2, 14.4: every start is a commanded open. Over the shield it is
    /// refused with the island's shake; on a dark display, quietly. Either
    /// way nothing starts and the panel is asked for nothing.
    func testACommandedStartRoutesThroughTheCommandedOpenRefusals() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.isLockedPresentation = true
        XCTAssertEqual(vm.togglePrompter(), .refused)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the refusal over the shield is the shake")

        vm.isLockedPresentation = false
        panel.screensAsleep = true
        XCTAssertEqual(vm.togglePrompter(), .refused)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(vm.lockedHoverNudges, 1, "nothing shakes on a dark display")
        XCTAssertTrue(panel.presented.isEmpty)
        XCTAssertFalse(lease.isHeld)

        panel.screensAsleep = false
        XCTAssertEqual(vm.togglePrompter(), .openStage)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(panel.presented, [.openStage])
    }

    /// E-43: the open hot key and the toggle hot key on a panel already showing
    /// a session change nothing about the hold; the toggle pauses and resumes.
    func testTheToggleKeyPausesAndResumesALiveSession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.togglePrompter()
        vm.togglePrompter()
        XCTAssertEqual(session.state, .paused(.user))
        vm.togglePrompter()
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(panel.presented, [.openStage, .openStage, .openStage], "each press shows the stage")
        XCTAssertEqual(session.generation, 1, "pausing and resuming is the same run")
    }

    /// 11.9, E-51: a start during the first-run welcome retires it through
    /// `chooseTab`, which also answers the welcome.
    func testAStartRetiresTheWelcome() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.isShowingWelcome = true

        vm.togglePrompter()
        XCTAssertFalse(vm.isShowingWelcome)
        XCTAssertEqual(firstRunAnswers, 1, "a shortcut that asks for a tab answers the welcome")
        XCTAssertEqual(vm.tab, .prompter)
        XCTAssertFalse(vm.wantsKeyboard, "the stage never takes the keyboard")
    }

    /// 7.3: the stage owns the body, so nothing moves the panel to another tab
    /// during a session: not the pointer, not a click, not a shortcut.
    func testTheTabCannotChangeDuringASession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.togglePrompter()

        vm.select(.media)
        vm.chooseTab(.translate)
        vm.clickOpened(pointerIsOnPanel: true)
        XCTAssertEqual(vm.tab, .prompter)
        XCTAssertFalse(vm.wantsKeyboard)

        vm.stopPrompter()
        vm.select(.media)
        XCTAssertEqual(vm.tab, .media, "Stop gives the rail back")
    }

    /// E-20: with nothing to read, a start opens the tab (which says why)
    /// rather than starting or doing nothing.
    func testAStartWithNothingToReadOpensTheTab() throws {
        let feature = makeFeature()
        try addScript(to: feature, pages: ["   ", "\n\n"])
        let vm = try makeModel(feature)

        XCTAssertEqual(vm.togglePrompter(), .openTab)
        XCTAssertEqual(try session(feature).state, .idle)
        XCTAssertEqual(vm.tab, .prompter)
        XCTAssertFalse(lease.isHeld)
    }

    // MARK: Shared displays

    /// 11.6, E-48: on a mirrored display a start asks first, inline, through
    /// the tab's arm-then-confirm control. Cancelling starts nothing;
    /// confirming starts the session.
    func testAMirroredDisplayAsksBeforeStarting() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)
        panel.share = .mirrored

        XCTAssertEqual(vm.togglePrompter(), .openTab)
        XCTAssertEqual(vm.pendingMirroredStart, .mirrored)
        XCTAssertEqual(session.state, .idle, "nothing starts before the answer")
        XCTAssertEqual(vm.tab, .prompter, "the question is asked where the control row is")
        XCTAssertFalse(lease.isHeld)

        vm.cancelMirroredStart()
        XCTAssertNil(vm.pendingMirroredStart)
        XCTAssertEqual(session.state, .idle)

        vm.togglePrompter()
        XCTAssertEqual(vm.confirmMirroredStart(), .openStage)
        XCTAssertNil(vm.pendingMirroredStart)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(panel.presented.last, .openStage)
        XCTAssertEqual(panel.shareChecks, 2, "asked once per start, not again on the confirmation")
    }

    /// 11.6: the heading's other case. A laptop presenting with its lid shut
    /// shows the island on the only display there is, the audience's.
    func testASoleExternalDisplayAsksToo() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        panel.share = .soleExternal

        vm.togglePrompter()
        XCTAssertEqual(vm.pendingMirroredStart, .soleExternal)
        XCTAssertEqual(try session(feature).state, .idle)
        XCTAssertFalse(PrompterDisplayShare.mirrored.message.isEmpty)
        XCTAssertFalse(PrompterDisplayShare.soleExternal.message.isEmpty)
        XCTAssertNotEqual(PrompterDisplayShare.mirrored.message, PrompterDisplayShare.soleExternal.message)
    }

    /// "Leaving the row cancels": the panel folding, the tab changing and Stop
    /// each take the question back, and a confirmation with no question
    /// pending starts nothing.
    func testLeavingTheQuestionCancelsIt() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)
        panel.share = .mirrored

        vm.togglePrompter()
        vm.isOpen = true
        vm.isOpen = false
        XCTAssertNil(vm.pendingMirroredStart, "the panel folding cancels")

        vm.togglePrompter()
        vm.select(.media)
        XCTAssertNil(vm.pendingMirroredStart, "leaving the tab cancels")

        vm.togglePrompter()
        vm.stopPrompter()
        XCTAssertNil(vm.pendingMirroredStart, "Stop cancels")

        XCTAssertEqual(vm.confirmMirroredStart(), .nothing)
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: Keep awake

    /// 11.8 and ruling 20.2 #12: the lease is held while running or paused by
    /// the user and released on every other path, start to quit, and never
    /// taken twice or released twice.
    func testTheKeepAwakeLeaseBeginsAndEndsOnEveryPath() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.togglePrompter()
        XCTAssertTrue(lease.isHeld, "start")
        vm.togglePrompter()
        XCTAssertTrue(lease.isHeld, "a user pause keeps the display awake")
        vm.togglePrompter()
        session.handle(.screenLocked)
        XCTAssertFalse(lease.isHeld, "a lock pause lets the display sleep")
        session.handle(.screenUnlocked)
        XCTAssertFalse(lease.isHeld, "unlock leaves it released")
        vm.togglePrompter()
        XCTAssertTrue(lease.isHeld, "resume")
        session.handle(.displaysSlept)
        XCTAssertFalse(lease.isHeld, "sleep")
        session.handle(.woke)
        XCTAssertFalse(lease.isHeld, "wake leaves it released")
        vm.togglePrompter()
        XCTAssertTrue(lease.isHeld)
        session.handle(.screenParametersChanged)
        XCTAssertTrue(lease.isHeld, "a display change does not touch it")
        readToTheEnd()
        XCTAssertEqual(session.state, .finished)
        XCTAssertFalse(lease.isHeld, "finish")
        vm.stopPrompter()
        XCTAssertFalse(lease.isHeld, "stop")

        vm.togglePrompter()
        XCTAssertTrue(lease.isHeld)
        vm.stopPrompter()
        XCTAssertFalse(lease.isHeld, "stop from running")

        vm.togglePrompter()
        session.handle(.appWillTerminate)
        XCTAssertEqual(session.state, .ended, "quit ends the session")
        XCTAssertFalse(lease.isHeld, "quit")

        vm.togglePrompter()
        feature.parts?.settings.keepAwake = false
        XCTAssertFalse(lease.isHeld, "the setting applies to a live session at once")
        feature.parts?.settings.keepAwake = true
        XCTAssertTrue(lease.isHeld)

        let token = NotchViewModel.follow(feature) { vm }
        feature.set(false)
        XCTAssertFalse(lease.isHeld, "switch-off")
        token.cancel()

        XCTAssertFalse(lease.unbalanced, "never begun twice or ended twice")
    }

    /// With Keep Display Awake off, no session takes the lease at all.
    func testNoLeaseWhenKeepAwakeIsOff() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        feature.parts?.settings.keepAwake = false
        let vm = try makeModel(feature)

        vm.togglePrompter()
        XCTAssertEqual(try session(feature).state, .running)
        XCTAssertEqual(lease.begins, 0)
    }

    // MARK: Settings

    /// 8.1, 8.6: speed applies to the running session; auto-next and its delay
    /// are read at the next page end; all of them come from the settings.
    func testTheSessionReadsItsSettingsAndFollowsThemLive() throws {
        let feature = makeFeature()
        try addScript(to: feature, pages: ["One two three.", "Four five six."])
        let settings = try XCTUnwrap(feature.parts?.settings)
        settings.speed = 5
        settings.autoNext = true
        settings.autoNextDelay = 1
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.togglePrompter()
        XCTAssertEqual(session.speed, 5)
        XCTAssertTrue(session.autoNext)
        XCTAssertEqual(session.autoNextDelay, 1)

        settings.speed = 2.5
        XCTAssertEqual(session.speed, 2.5, "a speed change reaches the running session")
        settings.autoNextDelay = 5
        XCTAssertEqual(session.autoNextDelay, 5)

        readToTheEnd()
        XCTAssertEqual(session.pageIndex, 1, "auto-next took it to the second page")
    }

    /// Start begins on the page the tab has selected.
    func testAStartBeginsOnTheSelectedPage() throws {
        let feature = makeFeature()
        try addScript(to: feature, pages: ["First page.", "Second page.", "Third page."])
        let vm = try makeModel(feature)
        vm.prompterPage = 2

        vm.togglePrompter()
        XCTAssertEqual(try session(feature).pageIndex, 2)
    }

    /// T10: the tab's page follows the tab's model into the view model, and
    /// a rebuilt panel (a fresh view model on the same parts) starts where
    /// the last one was left, so a hot-key start after a display change does
    /// not begin at page one.
    func testARebuiltPanelStartsOnThePageTheTabWasOn() throws {
        let feature = makeFeature()
        try addScript(to: feature, pages: ["First page.", "Second page.", "Third page."])
        let tab = try XCTUnwrap(feature.parts?.tab)
        let first = try makeModel(feature)
        tab.selectPage(2)
        XCTAssertEqual(first.prompterPage, 2, "a page chosen in the tab is the page a start reads")

        let rebuilt = try makeModel(feature)
        XCTAssertEqual(rebuilt.prompterPage, 2)
        rebuilt.togglePrompter()
        XCTAssertEqual(try session(feature).pageIndex, 2)
    }

    // MARK: Switch

    /// 4, 7.1 "Switch turned off", E-45: turning the switch off during a
    /// session ends it through the same Stop the button takes, before the
    /// call returns, and the panel loses the session and the tab together.
    func testTurningTheSwitchOffStopsTheSessionThroughTheStopPathAtOnce() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)
        let token = NotchViewModel.follow(feature) { vm }
        defer { token.cancel() }

        vm.togglePrompter()
        feature.set(false)

        XCTAssertEqual(session.state, .ended, "stopped before `set(false)` returned")
        XCTAssertEqual(panel.presented.last, .release, "through the Stop path, which lets the panel go")
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(scheduler.liveRepeating.count, 0, "no clock left running")
        XCTAssertNil(vm.prompterSession)
        XCTAssertFalse(vm.prompterEnabled)
        XCTAssertNotEqual(vm.tab, .prompter)
        XCTAssertFalse(vm.holdsOpen)

        // And on again: the new parts reach the panel.
        feature.set(true)
        XCTAssertNotNil(vm.prompterSession)
        XCTAssertTrue(vm.prompterSession !== session, "a fresh session for a fresh switch")
    }

    /// E-44: with the switch off the Prompter's commands do nothing, and its
    /// two hot keys are not registered even with their handlers installed.
    func testWithTheSwitchOffTheCommandsDoNothing() throws {
        let feature = makeFeature(enabled: false)
        let vm = try makeModel(feature)

        XCTAssertNil(vm.prompterSession)
        XCTAssertEqual(vm.togglePrompter(), .nothing)
        XCTAssertEqual(vm.stopPrompter(), .nothing)
        XCTAssertEqual(vm.confirmMirroredStart(), .nothing)
        XCTAssertTrue(panel.presented.isEmpty)
        XCTAssertEqual(panel.shareChecks, 0, "not even the displays are read")
        XCTAssertEqual(lease.begins, 0)

        var registered: [HotKeyBinding] = []
        let center = HotKeyCenter(defaults: defaults) { binding, _ in
            registered.append(binding)
            return nil
        }
        center.refuseSound = {}
        center.install([.prompterToggle: {}, .prompterStop: {}])
        center.setFeature(.prompter, enabled: false)
        XCTAssertTrue(registered.isEmpty, "a handler alone registers nothing while the switch is off")
    }

    // MARK: Generation

    /// E-34, 7.2: Start, Stop, Start within 0.4 s leaves exactly one live run,
    /// and nothing scheduled by the first can touch the second.
    func testStartStopStartWithinAFractionOfASecondLeavesOneSession() throws {
        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        let session = try session(feature)

        vm.togglePrompter()
        let firstTicks = scheduler.liveRepeating
        scheduler.advance(by: 0.1)
        vm.stopPrompter()
        scheduler.advance(by: 0.1)
        vm.togglePrompter()
        scheduler.advance(by: 0.1)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.generation, 3, "start, stop, start")
        XCTAssertEqual(scheduler.liveRepeating.count, 1, "one clock")

        // The first run's ticker, dequeued just as it was cancelled, fires
        // anyway: it must not move the second run.
        let progress = session.progress
        for entry in firstTicks { entry.action() }
        XCTAssertEqual(session.progress, progress)
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(lease.isHeld)
        XCTAssertFalse(lease.unbalanced)
        XCTAssertTrue(vm.holdsOpen)
    }

    // MARK: Escape

    /// 5.4: plain Escape is never claimed by the Prompter. Not through a pin
    /// (a session never pins, and a pin standing during a session gives up
    /// its claim), and not as a hot key of its own.
    func testPlainEscapeIsNeverClaimedByThePrompter() throws {
        XCTAssertFalse(
            NotchViewModel.claimsEscape(
                pinned: true, panelHasKeyboard: false, appIsActive: false, locked: false, sessionHoldsPanel: true
            ),
            "a pin standing during a session must not take Escape from the slideshow in front"
        )
        XCTAssertTrue(
            NotchViewModel.claimsEscape(
                pinned: true, panelHasKeyboard: false, appIsActive: false, locked: false, sessionHoldsPanel: false
            ),
            "without a session the pin's claim is unchanged"
        )

        let feature = makeFeature()
        try addScript(to: feature)
        let vm = try makeModel(feature)
        vm.isPinnedOpen = true
        vm.togglePrompter()
        XCTAssertFalse(
            NotchViewModel.claimsEscape(
                pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false,
                locked: vm.isLockedPresentation, sessionHoldsPanel: vm.prompterHoldsPanel
            )
        )
        XCTAssertFalse(vm.consumeEscape(), "the panel's own Escape does not stop a session either")
        XCTAssertEqual(try session(feature).state, .running)

        let plainEscape = HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: 0)
        for action in [HotKeyAction.prompterToggle, .prompterStop] {
            XCTAssertNotEqual(action.defaultBinding, plainEscape)
            XCTAssertNotEqual(action.defaultBinding.keyCode, UInt32(kVK_Escape))
        }
    }
}

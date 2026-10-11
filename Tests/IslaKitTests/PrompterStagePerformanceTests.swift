import AppKit
import XCTest
@testable import IslaKit

/// E-26: a page of 100,000 words. Tokenizing and laying it out never happen
/// on the main thread, the first screenful is there at once, a result that
/// went stale while it was being made is dropped, and finding what to draw
/// for a frame does not grow with the page.
///
/// Budgets, from debug-build measurements on this Mac (2026-10-12), with wide
/// margins so a loaded CI runner does not flake:
/// - tokenizing the 100,000-word page: 155 ms, which is why it is never done
///   on the main thread; 64 KB of script (12,000 words) took 18 ms, so the
///   start tokenizes at once only up to 32 KB (about 9 ms);
/// - the full 100,000-word layout: 27 ms with the fixed-width measurer and
///   27 ms with CoreText (one measurement per distinct word); held under
///   10 s, because the point here is *where* it runs, not how fast;
/// - a 2,000-word page laid out where it is asked for (CoreText): 1.8 ms;
/// - the first screenful of the big page on the main thread: 0.1 ms; held
///   under 50 ms (three frames at 60 Hz);
/// - the visible slice plus the scroll target for one frame: 0.85 µs; held
///   under 200 µs averaged over 20,000 frames, one eightieth of a 16.7 ms
///   frame.
@MainActor
final class PrompterStagePerformanceTests: XCTestCase {
    private static let bigPage = promptFixturePage(words: 100_000)

    // MARK: Layout

    func testAHundredThousandWordPageLaysOutOffTheMainThread() async throws {
        let script = PromptScript(Self.bigPage)
        XCTAssertGreaterThanOrEqual(script.words.count, 100_000)

        let ledger = ThreadLedger()
        var measurer = FixedWidthMeasurer()
        measurer.onMeasure = { ledger.record(onMain: $0) }
        let rig = StageRig()
        let stage = rig.stage(measurer: measurer, runner: PrompterStageModel.backgroundRunner)
        XCTAssertTrue(rig.session.start(pages: [script]))

        let clock = ContinuousClock()
        let firstScreen = clock.measure {
            stage.setViewport(CGSize(width: 408, height: 120))
        }
        let prefix = try XCTUnwrap(stage.layout, "the first screenful is drawn at once")
        XCTAssertFalse(prefix.isComplete, "and only the first screenful")
        XCTAssertLessThan(prefix.lines.count, 100)
        XCTAssertLessThan(firstScreen, .milliseconds(50), "first screenful took \(firstScreen)")
        let measuredOnMain = ledger.counts.main
        XCTAssertLessThan(measuredOnMain, 2_000, "the main thread measured only the screenful")

        let started = clock.now
        await stage.layoutSettled()
        let elapsed = clock.now - started
        let layout = try XCTUnwrap(stage.layout)
        XCTAssertTrue(layout.isComplete, "the whole page arrived")
        XCTAssertEqual(layout.lineOfWord.count, script.words.count)
        XCTAssertEqual(ledger.counts.main, measuredOnMain, "nothing more was measured on the main thread")
        XCTAssertGreaterThan(ledger.counts.other, 0, "the page was measured on the background task")
        XCTAssertLessThan(elapsed, .seconds(10), "the full layout took \(elapsed)")
        // The top of the full layout is the screenful that stood in for it.
        XCTAssertEqual(Array(layout.lines.prefix(prefix.lines.count)), prefix.lines)
        rig.session.stop()
        XCTAssertNil(stage.layout, "Stop lets the page go")
        XCTAssertEqual(stage.cachedLayoutCount, 0)
    }

    /// A layout that finishes after the page changed under it is dropped,
    /// never drawn over the page that replaced it.
    func testAStaleBackgroundLayoutIsDropped() async throws {
        let rig = StageRig()
        let stage = rig.stage(runner: PrompterStageModel.backgroundRunner)
        let small = PromptScript("a short second page")
        XCTAssertTrue(rig.session.start(pages: [PromptScript(Self.bigPage), small]))
        stage.setViewport(CGSize(width: 408, height: 120))
        XCTAssertNotNil(stage.layoutTask, "the big page is being laid out")
        rig.read(for: 0.05)
        XCTAssertTrue(rig.session.goToPage(1))
        let current = try XCTUnwrap(stage.layout)
        XCTAssertTrue(current.isComplete)
        XCTAssertEqual(current.lineOfWord.count, small.words.count)
        try await Task.sleep(for: .seconds(1))
        await stage.layoutSettled()
        XCTAssertEqual(stage.layout?.lineOfWord.count, small.words.count, "the old page's layout never landed")
        rig.session.stop()
    }

    /// Per frame the stage asks for the lines inside the region plus 400 pt
    /// either side and for the scroll target: both by binary search.
    func testTheVisibleSliceStaysInsideAFrameBudget() {
        let script = PromptScript(Self.bigPage)
        let layout = PromptFlowLayout.layout(
            script, measurer: FixedWidthMeasurer(), columnWidth: 360, dividers: true)
        let geometry = PromptScrollGeometry(layout: layout, viewport: 120, placement: .centered)
        let frames = 20_000
        let step = Double(script.words.count) / Double(frames)
        var drawn = 0
        let clock = ContinuousClock()
        let total = clock.measure {
            for frame in 0..<frames {
                let offset = geometry.offset(forProgress: Double(frame) * step, in: script, interpolates: true)
                let range = layout.lines(
                    intersecting: -offset - PrompterStageMetrics.cullBuffer,
                    -offset + 120 + PrompterStageMetrics.cullBuffer)
                drawn = max(drawn, range.count)
            }
        }
        XCTAssertLessThan(drawn, 40, "a frame draws a few dozen lines, not the page")
        XCTAssertGreaterThan(drawn, 3)
        let perFrame = total / frames
        XCTAssertLessThan(perFrame, .microseconds(200), "one frame's slice took \(perFrame)")
    }

    // MARK: Tokenizing at start

    /// A small script starts at once, as before; a big one is tokenized on a
    /// background task and starts when that lands.
    func testABigScriptIsTokenizedOffTheMainThread() async throws {
        let onMain = await PrompterBackground.run { Thread.isMainThread }
        XCTAssertFalse(onMain, "the background runner is not the main thread")

        let fixture = try StartFixture()
        defer { fixture.release() }
        try fixture.addScript([Self.bigPage])
        XCTAssertFalse(PrompterParts.tokenizesAtOnce([Self.bigPage]))
        XCTAssertTrue(PrompterParts.tokenizesAtOnce(["a short talk"]))

        XCTAssertEqual(fixture.vm.startPrompter(), .nothing, "nothing to show until the page is ready")
        XCTAssertEqual(fixture.session.state, .idle)
        XCTAssertTrue(fixture.vm.isPreparingPrompter)
        XCTAssertEqual(fixture.vm.startPrompter(), .nothing, "a second press while preparing does nothing")

        let deadline = ContinuousClock.now + .seconds(20)
        while fixture.session.state == .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.session.state, .running)
        XCTAssertFalse(fixture.vm.isPreparingPrompter)
        XCTAssertEqual(fixture.panel.presented.last, .openStage)
        XCTAssertGreaterThanOrEqual(fixture.session.script?.words.count ?? 0, 100_000)
        fixture.vm.stopPrompter()
    }

    /// Stop while the page is still being tokenized calls the start off: the
    /// result arrives to a model that no longer wants it.
    func testAStopWhilePreparingDropsTheStart() async throws {
        let fixture = try StartFixture()
        defer { fixture.release() }
        try fixture.addScript([Self.bigPage])
        let gate = Gate()
        fixture.vm.prompterTokenize = { texts in
            await gate.wait()
            return texts.map(PromptScript.init)
        }
        XCTAssertEqual(fixture.vm.startPrompter(), .nothing)
        XCTAssertTrue(fixture.vm.isPreparingPrompter)
        XCTAssertEqual(fixture.vm.stopPrompter(), .nothing)
        XCTAssertFalse(fixture.vm.isPreparingPrompter)
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.session.state, .idle, "the stale result was dropped")
        XCTAssertFalse(fixture.panel.presented.contains(.openStage))

        // And a start after it works.
        let second = Gate()
        fixture.vm.prompterTokenize = { texts in
            await second.wait()
            return texts.map(PromptScript.init)
        }
        fixture.vm.startPrompter()
        second.open()
        let deadline = ContinuousClock.now + .seconds(20)
        while fixture.session.state == .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.session.state, .running)
        fixture.vm.stopPrompter()
    }
}

// MARK: - Fixtures

/// Lets a fake tokenizer finish only when the test says so.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }

    var isOpenNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    func wait() async {
        while !isOpenNow {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The controller's half of a start, recorded.
@MainActor
final class StartPanel {
    var screensAsleep = false
    var share: PrompterDisplayShare?
    private(set) var presented: [PrompterPresentation] = []

    var hooks: PrompterPanelHooks {
        PrompterPanelHooks(
            screensAsleep: { [unowned self] in self.screensAsleep },
            displayShare: { [unowned self] in self.share },
            present: { [unowned self] in self.presented.append($0) }
        )
    }
}

/// A view model with the switch on, on isolated stores, wired the way the
/// controller's `build()` wires it (the recipe `PrompterHoldTests` uses).
@MainActor
final class StartFixture {
    let rig = StageRig()
    let feature: PrompterFeature
    let vm: NotchViewModel
    let panel = StartPanel()
    private let cleanup: () -> Void

    var session: PrompterSession { feature.parts!.session }

    init() throws {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: PrompterFeature.enabledKey)
        let rig = self.rig
        feature = PrompterFeature(defaults: defaults) { defaults in
            PrompterParts(
                settings: PrompterSettings(defaults: defaults),
                library: PrompterLibrary(io: StageFileIO(), scheduler: rig.scheduler),
                session: PrompterSession(now: { rig.time.now }, scheduler: rig.scheduler, keepAwake: rig.lease)
            )
        }
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrompterStageTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "com.ctimothe.isla.prompterstage.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ctimothe.isla.prompterstage.\(UUID().uuidString)"))
        cleanup = {
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
        vm = NotchViewModel(geometry: geometry, stores: stores, prompterEnabled: true)
        vm.recordFirstRunAnswered = {}
        vm.prompterHooks = panel.hooks
        vm.attachPrompter(feature.parts)
    }

    /// Removes the temporary folder, the defaults suite and the pasteboard.
    func release() {
        cleanup()
    }

    func addScript(_ pages: [String]) throws {
        let library = try XCTUnwrap(feature.parts?.library)
        let id = try library.addScript(title: "Talk", pages: pages)
        library.setCurrentScript(id)
    }
}

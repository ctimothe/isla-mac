import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The stage as VoiceOver meets it (spec 15): the page is one element whose
/// value is the line being read and how far through the page reading is, not
/// a stop per word; every control has a name; Stop is the panel's Stop, not
/// the session's; and state changes are spoken once, through the announcer.
///
/// Hosted offscreen with `AXProbe`, on a session driven by fake time: nothing
/// here reaches a real timer, the defaults, or the live app.
@MainActor
final class PrompterAccessibilityTests: XCTestCase {
    /// The standard body's content at the default width: 560 less the 14 pt
    /// padding each side, 208 less a 32 pt notch row and 14 pt underneath.
    private static let size = CGSize(width: 532, height: 162)

    private func host(_ rig: StageRig, _ stage: PrompterStageModel, stops: @escaping () -> Void = {}) -> PrompterStage {
        PrompterStage(
            session: rig.session, settings: rig.settings, stage: stage,
            reduceMotion: false, increaseContrast: false, reduceTransparency: false,
            stop: stops
        )
    }

    func testThePageIsOneElementThatSaysTheLineAndHowFarIn() async throws {
        let rig = StageRig()
        let stage = rig.stage()
        let script = PromptScript("Good evening everyone. [smile] Thank you all for coming out tonight to hear this.")
        XCTAssertTrue(rig.session.start(pages: [script]))
        let tree = await AXProbe.tree(of: host(rig, stage), size: Self.size)

        let page = try XCTUnwrap(tree.first(label: localized("Script")), tree.dump)
        XCTAssertTrue(page.value.hasPrefix("Good evening"), "the value is the line being read: \(page.value)\n\(tree.dump)")
        XCTAssertTrue(page.value.hasSuffix("0%"), "and how far in: \(page.value)")
        XCTAssertTrue(page.children.isEmpty, "no stop per word")
        let words = tree.all { $0.label == "evening" || $0.value == "evening" || $0.title == "evening" }
        XCTAssertTrue(words.isEmpty, "a word is never an element of its own")
        rig.session.stop()
    }

    /// The value follows reading: a line further on, a larger percentage.
    func testTheValueTracksTheCurrentLine() throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript("aaaa bbbb cccc dddd eeee ffff gggg hhhh")]))
        stage.setViewport(CGSize(width: 148, height: 100))
        XCTAssertEqual(stage.accessibilityValue, localized("%@, %d%%", "aaaa bbbb", 0))
        rig.read(for: 2.05)
        XCTAssertEqual(stage.accessibilityValue, localized("%@, %d%%", "gggg hhhh", 76))
        rig.session.stop()
    }

    func testEveryControlHasAName() async throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript("one page"), PromptScript("and another")]))
        let tree = await AXProbe.tree(of: host(rig, stage), size: Self.size)
        for name in ["Next Page", "Pause", "Slower", "Faster", "Stop"] {
            XCTAssertNotNil(tree.first(label: localized(name)), "\(name) is named\n\(tree.dump)")
        }
        let chip = try XCTUnwrap(tree.first(label: localized("Next Page")))
        XCTAssertEqual(chip.value, localized("Page %d of %d", 1, 2))
        let faster = try XCTUnwrap(tree.first(label: localized("Faster")))
        XCTAssertFalse(faster.value.isEmpty, "the speed is said, not only shown")
        rig.session.stop()
    }

    /// The stage's Stop is the panel's Stop (`NotchViewModel.stopPrompter`),
    /// so the panel lets go the way it does for the hot key. Pressing it
    /// never reaches past that to the session itself.
    func testStopGoesThroughThePanelNotTheSession() async throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript("one two three")]))
        var stops = 0
        let tree = await AXProbe.tree(of: host(rig, stage, stops: { stops += 1 }), size: Self.size)
        XCTAssertTrue(try XCTUnwrap(tree.first(label: localized("Stop"))).press())
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(rig.session.state, .running, "the stage itself never stops the session")
        rig.session.stop()
    }

    /// Pause and resume are spoken; a scroll's own pause is not; the end of
    /// the page is spoken once per arrival; Stop is spoken. Start is spoken by
    /// the start itself, not again here.
    func testStateChangesAreAnnouncedOnce() {
        let rig = StageRig()
        let stage = rig.stage()
        var said: [String] = []
        stage.announce = { said.append($0) }
        XCTAssertTrue(rig.session.start(pages: [PromptScript("aaaa bbbb cccc dddd eeee ffff"), PromptScript("more")]))
        stage.setViewport(CGSize(width: 148, height: 100))
        XCTAssertEqual(said, [], "start is said by the start")

        rig.session.togglePlayback()
        rig.session.togglePlayback()
        XCTAssertEqual(said, [localized("Prompter paused"), localized("Prompter resumed")])

        said.removeAll()
        stage.wheel(deltaY: -28, final: true)
        XCTAssertEqual(rig.session.state, .running)
        XCTAssertEqual(said, [], "a scroll's own pause and resume are not news")

        rig.session.setSpeed(8)
        rig.read(for: 3)
        XCTAssertEqual(rig.session.state, .finished)
        XCTAssertEqual(said, [localized("End of page")])
        XCTAssertTrue(rig.session.nextPage())
        rig.read(for: 1)
        XCTAssertEqual(said, [localized("End of page"), localized("End of script")])

        rig.session.stop()
        XCTAssertEqual(said.last, localized("Prompter stopped"))
    }

    func testTheAnnouncementTable() {
        typealias S = PrompterStageSpeech
        XCTAssertNil(S.announcement(from: .idle, to: .running, hasNextPage: false))
        XCTAssertNil(S.announcement(from: .ended, to: .running, hasNextPage: false))
        XCTAssertNil(S.announcement(from: .running, to: .paused(.lock), hasNextPage: false), "the lock is the news")
        XCTAssertNil(S.announcement(from: .running, to: .paused(.sleep), hasNextPage: false))
        XCTAssertNil(S.announcement(from: .running, to: .running, hasNextPage: false))
        XCTAssertNil(S.announcement(from: .idle, to: .ended, hasNextPage: false), "nothing was running")
        XCTAssertEqual(S.announcement(from: .paused(.lock), to: .running, hasNextPage: false), localized("Prompter resumed"))
        XCTAssertEqual(S.announcement(from: .running, to: .finished, hasNextPage: true), localized("End of page"))
        XCTAssertEqual(S.announcement(from: .paused(.user), to: .ended, hasNextPage: true), localized("Prompter stopped"))
    }

    /// The stage never asks for more than the body it is given (the lyrics
    /// stage's lesson: a taller ask puts the reading line below the edge).
    func testTheStageFitsTheStandardBody() {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(promptFixturePage(words: 400))]))
        let hosting = NSHostingController(rootView: host(rig, stage))
        let wanted = hosting.sizeThatFits(in: Self.size)
        XCTAssertLessThanOrEqual(wanted.height, Self.size.height)
        XCTAssertLessThanOrEqual(wanted.width, Self.size.width)
        rig.session.stop()
    }

    /// The shared-display question (11.6): its message, Start Anyway that
    /// arms before it confirms, and Cancel.
    func testTheSharedDisplayQuestionIsNamed() async throws {
        var confirmed = 0
        var cancelled = 0
        let question = PrompterShareQuestion(
            share: .mirrored, confirm: { confirmed += 1 }, cancel: { cancelled += 1 })
        let tree = await AXProbe.tree(of: question, size: Self.size)
        XCTAssertNotNil(tree.all { $0.value == PrompterDisplayShare.mirrored.message || $0.label == PrompterDisplayShare.mirrored.message }.first,
                        tree.dump)
        let start = try XCTUnwrap(tree.first(label: PrompterDisplayShare.confirmTitle))
        XCTAssertTrue(start.press())
        XCTAssertEqual(confirmed, 0, "the first press only arms")
        XCTAssertTrue(try XCTUnwrap(tree.first(label: localized("Cancel"))).press())
        XCTAssertEqual(cancelled, 1)
    }
}

/// Spec 5.2 in the real panel: while a session holds it the stage owns the
/// body and the rail is gone; before and after, the rail is there.
@MainActor
final class PrompterStageHookTests: XCTestCase {
    func testTheStageReplacesTheRailOnlyWhileASessionHoldsThePanel() async throws {
        let fixture = try StartFixture()
        defer { fixture.release() }
        try fixture.addScript(["Good evening everyone, and thank you for coming."])
        fixture.vm.isOpen = true
        fixture.vm.chooseTab(.prompter)
        let size = CGSize(width: fixture.vm.geometry.expandedSize.width, height: fixture.vm.geometry.expandedSize.height)

        let before = await AXProbe.tree(of: NotchContentView(vm: fixture.vm), size: size)
        XCTAssertNotNil(before.first(label: localized("Tabs")), "the rail is there before a start\n\(before.dump)")
        XCTAssertNil(before.first(label: localized("Script")))

        XCTAssertEqual(fixture.vm.startPrompter(), .openStage)
        let during = await AXProbe.tree(of: NotchContentView(vm: fixture.vm), size: size)
        XCTAssertNil(during.first(label: localized("Tabs")), "no rail during a session\n\(during.dump)")
        XCTAssertNotNil(during.first(label: localized("Script")), "the stage owns the body")
        // The strip is the one Isla element; its value carries the wings.
        let island = try XCTUnwrap(during.first(label: ProductIdentity.displayName), during.dump)
        XCTAssertTrue(island.value.contains(PrompterStageWings.captureChip(hidden: false)),
                      "the capture chip is said: \(island.value)")
        XCTAssertTrue(island.value.contains(localized("Elapsed time %@", "0:00")), "and the elapsed time: \(island.value)")

        fixture.vm.stopPrompter()
        let after = await AXProbe.tree(of: NotchContentView(vm: fixture.vm), size: size)
        XCTAssertNotNil(after.first(label: localized("Tabs")), "the rail is back after Stop")
        XCTAssertNil(after.first(label: localized("Script")))
    }

    /// The shared-display question shows in the Prompter tab's body, with
    /// the rail still there: no session exists yet (ruling 20.3 #8).
    func testTheSharedDisplayQuestionShowsInTheTab() async throws {
        let fixture = try StartFixture()
        defer { fixture.release() }
        try fixture.addScript(["Good evening everyone."])
        fixture.panel.share = .mirrored
        fixture.vm.isOpen = true
        XCTAssertEqual(fixture.vm.startPrompter(), .openTab)
        XCTAssertEqual(fixture.vm.pendingMirroredStart, .mirrored)
        let size = CGSize(width: fixture.vm.geometry.expandedSize.width, height: fixture.vm.geometry.expandedSize.height)
        let tree = await AXProbe.tree(of: NotchContentView(vm: fixture.vm), size: size)
        XCTAssertNotNil(tree.first(label: PrompterDisplayShare.confirmTitle), tree.dump)
        XCTAssertNotNil(tree.first(label: localized("Tabs")))
        let cancel = try XCTUnwrap(tree.first(label: localized("Cancel")))
        XCTAssertTrue(cancel.press())
        XCTAssertNil(fixture.vm.pendingMirroredStart)
    }
}

import AppKit
import XCTest
@testable import IslaKit

/// Where the stage puts the text and when it may move it (spec 10.3, 10.4,
/// 8.5, 10.6, E-28, E-30).
///
/// The fixture is exact arithmetic: 10 pt a letter, 5 pt a space, a 100 pt
/// column, so "aaaa bbbb" is a line and every line is 20 pt tall with 8 pt
/// under it (a 28 pt pitch).
@MainActor
final class PrompterScrollTests: XCTestCase {
    private let measurer = FixedWidthMeasurer()
    /// Twelve four-letter words: six lines of two.
    private let twelve = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll"

    private func geometry(
        _ text: String? = nil, column: Double = 100, viewport: Double = 100,
        placement: PrompterReadingPosition = .centered, measurer: FixedWidthMeasurer? = nil
    ) -> (PromptScript, PromptScrollGeometry) {
        let script = PromptScript(text ?? twelve)
        let layout = PromptFlowLayout.layout(
            script, measurer: measurer ?? self.measurer, columnWidth: column, dividers: false)
        return (script, PromptScrollGeometry(layout: layout, viewport: viewport, placement: placement))
    }

    // MARK: - Targets (10.3, 10.4)

    /// Centered: the active line's middle on the region's middle. At the
    /// start that is the first line at the centre less half a line (10.4).
    func testCenteredPutsTheActiveLineOnTheMiddle() {
        let (script, g) = geometry()
        XCTAssertEqual(g.guideY, 50)
        XCTAssertEqual(g.offset(forLine: 0), 40, "first line: 50 less half its 20 pt")
        XCTAssertEqual(g.offset(forLine: 3), 40 - 3 * 28)
        XCTAssertEqual(g.offset(forProgress: 0, in: script, interpolates: true), 40)
        XCTAssertEqual(g.offset(forProgress: 6, in: script, interpolates: true), 40 - 3 * 28)
    }

    /// Near Top: the active line one line below the top with the previous
    /// line above it; the first line itself at the top (10.4).
    func testNearTopKeepsThePreviousLineInView() {
        let (_, g) = geometry(placement: .nearTop)
        XCTAssertEqual(g.offset(forLine: 0), 0, "the start is at the top")
        XCTAssertEqual(g.offset(forLine: 1), 0, "line 1 sits one pitch down, line 0 above it")
        XCTAssertEqual(g.offset(forLine: 4), -3 * 28)
        XCTAssertEqual(g.guideY, 28 + 10, "the guide is the middle of the second line")
    }

    /// Timer modes move between the midpoints of the active word and the next
    /// by the fractional progress: still within a line, gliding across a
    /// line break over the last word's time.
    func testTimerModesInterpolateBetweenWordMidpoints() {
        let (script, g) = geometry()
        XCTAssertEqual(g.offset(forProgress: 0.5, in: script, interpolates: true), 40, "both words on line 0")
        XCTAssertEqual(g.offset(forProgress: 1.5, in: script, interpolates: true), 40 - 14, "half way to line 1")
        XCTAssertEqual(g.offset(forProgress: 1.25, in: script, interpolates: true), 40 - 7)
        XCTAssertEqual(g.offset(forProgress: 1.5, in: script, interpolates: false), 40, "tracking does not interpolate")
        // Clamped at both ends (E-30).
        XCTAssertEqual(g.offset(forProgress: -4, in: script, interpolates: true), 40)
        XCTAssertEqual(g.offset(forProgress: 99, in: script, interpolates: true), g.offset(forLine: 5))
    }

    /// 10.4 end: the last line may reach the guide, and a floor keeps it at
    /// least `endClearance` above the control row, even in a region barely
    /// taller than a line.
    func testTheLastLineStaysClearOfTheControlRow() {
        let tall = FixedWidthMeasurer(metrics: PromptFontMetrics(pointSize: 26, ascender: 24, descender: -6, leading: 0))
        for placement in PrompterReadingPosition.allCases {
            for viewport in [40.0, 64, 100, 150] {
                let (script, g) = geometry(viewport: viewport, placement: placement, measurer: tall)
                let offset = g.offset(forProgress: Double(script.words.count), in: script, interpolates: true)
                let last = g.layout.lines.count - 1
                let bottom = g.layout.lineBottom(last) + offset
                XCTAssertLessThanOrEqual(
                    bottom, viewport - PromptScrollGeometry.endClearance + 1e-9,
                    "\(placement) in \(viewport) pt: the last line runs into the control row")
                XCTAssertGreaterThanOrEqual(g.layout.lines[last].top + offset, -1e-9, "and its top is still on screen")
            }
        }
        XCTAssertEqual(PromptScrollGeometry.endClearance, 8)
    }

    // MARK: - Forward only (10.3)

    func testMotionIsForwardOnlyUnlessABackwardUpdateIsArmed() {
        var planner = PromptScrollPlanner()
        XCTAssertTrue(planner.follow(40), "the first target is taken as it is")
        XCTAssertTrue(planner.follow(12), "forward")
        XCTAssertFalse(planner.follow(30), "18 pt backward is ignored")
        XCTAssertEqual(planner.displayed, 12)
        XCTAssertTrue(planner.follow(12.8), "within 1 pt is not a backward move")
        XCTAssertFalse(planner.follow(20))

        planner.armBackward()
        XCTAssertTrue(planner.follow(30), "a tap, a scroll end or a page change arms one")
        XCTAssertFalse(planner.follow(35), "exactly one")
        XCTAssertEqual(planner.displayed, 30)

        planner.armBackward()
        XCTAssertTrue(planner.follow(0), "an armed update spent going forward")
        XCTAssertFalse(planner.follow(20), "is spent all the same")
    }

    /// A layout change (width, size, font, page) re-anchors unconditionally:
    /// pixels from the old layout mean nothing in the new one.
    func testAReanchorIsNotSubjectToTheForwardRule() {
        var planner = PromptScrollPlanner()
        planner.follow(-200)
        planner.reanchor(-40)
        XCTAssertEqual(planner.displayed, -40)
        XCTAssertFalse(planner.backwardArmed)
    }

    /// E-28: after a column change the guide still holds the same word, not
    /// the same pixel.
    func testAWidthChangeReanchorsByOffsetNotByPixel() {
        let (script, narrow) = geometry(column: 100)
        let (_, wide) = geometry(column: 200)
        let progress = 6.0
        let word = 6
        let before = narrow.offset(forProgress: progress, in: script, interpolates: true)
        let after = wide.offset(forProgress: progress, in: script, interpolates: true)
        XCTAssertNotEqual(before, after, "the pixel changed")
        XCTAssertEqual(narrow.lineAtGuide(offset: before), narrow.layout.lineIndex(ofWord: word))
        XCTAssertEqual(wide.lineAtGuide(offset: after), wide.layout.lineIndex(ofWord: word), "the word did not")
    }

    // MARK: - Manual scroll (8.5, 10.4)

    /// Clamped to [-maxDown, maxUp]: between the first line and the last line
    /// at the guide. Past either end it gives 20 percent of the excess, and
    /// settles back on the end when the hand lets go.
    func testManualScrollIsClampedWithARubberBand() {
        let (_, g) = geometry()
        XCTAssertEqual(g.manualRange, (40 - 5 * 28)...40)
        XCTAssertEqual(PromptScrollPlanner.rubberBand(50, in: 0...40), 42)
        XCTAssertEqual(PromptScrollPlanner.rubberBand(-110, in: -100...40), -102)
        XCTAssertEqual(PromptScrollPlanner.rubberBand(10, in: -100...40), 10)

        var planner = PromptScrollPlanner()
        planner.follow(12)
        planner.beginManual()
        planner.scroll(by: 100, within: g.manualRange)
        XCTAssertEqual(planner.displayed, 40 + (112 - 40) * 0.2, accuracy: 1e-9)
        XCTAssertFalse(planner.follow(-60), "the clock does not move the text under a hand")
        planner.scroll(by: -100, within: g.manualRange)
        XCTAssertEqual(planner.displayed, 12, accuracy: 1e-9, "the band gives back what it took")
        planner.scroll(by: 60, within: g.manualRange)
        let settled = planner.endManual(within: g.manualRange)
        XCTAssertEqual(settled, 40, "let go past the end, it settles on the end")
        XCTAssertFalse(planner.isManual)
    }

    /// The resume position is the line under the guide where the wheel
    /// stopped, read from its first word; when the reader came back to the
    /// line already being read, reading continues where it was.
    func testTheWheelStoppingResumesFromTheLineUnderTheGuide() throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))  // a 100 pt column
        rig.read(for: 1.05)   // just past three words at 3 words a second
        XCTAssertEqual(rig.session.state, .running)

        stage.wheel(deltaY: -56, final: false)   // two lines on
        XCTAssertEqual(rig.session.state, .paused(.user), "a scroll pauses the clock while it lasts")
        rig.scheduler.advance(by: 0.1)
        XCTAssertEqual(rig.session.state, .paused(.user))
        rig.scheduler.advance(by: PrompterStageModel.wheelSettleDelay)
        XCTAssertEqual(rig.session.state, .running, "and resumes when the wheel stops")
        let current = try XCTUnwrap(rig.session.currentWordIndex)
        let layout = try XCTUnwrap(stage.layout)
        XCTAssertEqual(layout.lineIndex(ofWord: current), 3, "the line two below where reading was")
        XCTAssertEqual(current, 6, "from its first word")

        // A tiny nudge that leaves the same line under the guide changes
        // nothing about where reading stands.
        rig.read(for: 0.15)
        let before = rig.session.progress
        stage.wheel(deltaY: 3, final: true)
        XCTAssertEqual(rig.session.state, .running)
        XCTAssertEqual(rig.session.progress, before, accuracy: 1e-9)
        rig.session.stop()
    }

    /// Ruling 20.6 #2. A lock (or sleep) inside the wheel's settle window used
    /// to leave the scroll's own pause standing, so the settle resumed the
    /// clock behind the lock shield, took the display-awake lease back and let
    /// a countdown run the next page with nobody watching (20.2 #5, 11.3).
    func testALockDuringAScrollIsNeverResumedByTheWheel() {
        let events: [(String, (PrompterSession) -> Void)] = [
            ("lock", { $0.handle(.screenLocked) }),
            ("display sleep", { $0.handle(.displaysSlept) }),
            ("system sleep", { $0.handle(.systemWillSleep) }),
        ]
        for (name, event) in events {
            let rig = StageRig()
            let stage = rig.stage()
            XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
            stage.setViewport(CGSize(width: 148, height: 100))
            rig.read(for: 1.05)

            stage.wheel(deltaY: -56, final: false)
            XCTAssertEqual(rig.session.state, .paused(.user), name)
            event(rig.session)
            XCTAssertFalse(rig.lease.held, "\(name): the lease went with the display")

            // Momentum still arriving, then the settle window running out.
            stage.wheel(deltaY: -10, final: false)
            rig.scheduler.advance(by: PrompterStageModel.wheelSettleDelay * 4)
            stage.wheel(deltaY: -10, final: true)
            XCTAssertEqual(rig.session.state, .paused(.user), "\(name): the wheel gave nothing back")
            XCTAssertTrue(rig.session.isPausedBySystem, name)
            XCTAssertFalse(rig.lease.held, "\(name): and took nothing back")
            rig.read(for: 2)
            XCTAssertEqual(rig.session.state, .paused(.user), name)

            // The speaker's own resume still works, and the hand can scroll
            // again afterwards.
            rig.session.resume()
            XCTAssertEqual(rig.session.state, .running, name)
            stage.wheel(deltaY: -28, final: true)
            XCTAssertEqual(rig.session.state, .running, "\(name): a later scroll pauses and resumes as before")
            rig.session.stop()
        }
    }

    /// A display change drops the stage model; one dropped mid-scroll had a
    /// settle that could never fire, so the session stayed in a user pause
    /// nobody asked for. A model let go hands the scroll's pause back, unless
    /// the system paused the session meanwhile.
    func testAStageLetGoMidScrollHandsThePauseBack() {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.read(for: 1.05)
        stage.wheel(deltaY: -56, final: false)
        XCTAssertEqual(rig.session.state, .paused(.user))

        stage.relinquish()
        XCTAssertEqual(rig.session.state, .running, "the scroll's pause went back with the model")
        XCTAssertTrue(rig.scheduler.live.allSatisfy { $0.interval != nil }, "no settle left armed")
        rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.session.state, .running)

        // A pause the user made is theirs: letting a model go leaves it.
        rig.session.pause(.user)
        stage.relinquish()
        XCTAssertEqual(rig.session.state, .paused(.user))

        // And one the lock made stays too.
        rig.session.resume()
        let second = rig.stage()
        second.setViewport(CGSize(width: 148, height: 100))
        second.wheel(deltaY: -28, final: false)
        rig.session.handle(.screenLocked)
        second.relinquish()
        XCTAssertEqual(rig.session.state, .paused(.user))
        XCTAssertTrue(rig.session.isPausedBySystem)
        rig.session.stop()
    }

    /// Classic scrolls by hand only while running (8.5); a paused page does
    /// not move under the wheel.
    func testAPausedPageDoesNotScrollByHand() {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.session.pause(.user)
        let before = stage.offset
        stage.wheel(deltaY: -56, final: true)
        XCTAssertEqual(stage.offset, before)
        XCTAssertEqual(rig.session.state, .paused(.user))
        rig.session.stop()
    }

    /// A tap jumps there and arms the one backward move it needs (8.5).
    func testATapOnAnEarlierWordMovesTheTextBack() throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.read(for: 3.05)
        let ahead = stage.offset
        stage.tapWord(0)
        XCTAssertEqual(rig.session.currentWordIndex, 0)
        XCTAssertGreaterThan(stage.offset, ahead, "the text came back down to the first line")
        XCTAssertEqual(stage.offset, 40, accuracy: 1e-9)
        rig.session.stop()
    }

    /// A page change arms and re-anchors: the next page starts at its start.
    func testANewPageStartsAtItsStart() {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve), PromptScript("one two three")]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.read(for: 3.05)
        XCTAssertLessThan(stage.offset, 0)
        XCTAssertTrue(rig.session.nextPage())
        XCTAssertEqual(stage.offset, 40, accuracy: 1e-9)
        rig.session.stop()
    }

    /// A column change mid-session keeps the word being read at the guide
    /// (E-28), and the stage never lays out a page twice for one key.
    func testAColumnChangeMidSessionKeepsTheWordAtTheGuide() throws {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.read(for: 2.05)
        let word = try XCTUnwrap(rig.session.currentWordIndex)
        stage.setViewport(CGSize(width: 248, height: 100))   // a 200 pt column
        let layout = try XCTUnwrap(stage.layout)
        XCTAssertEqual(layout.columnWidth, 200)
        let g = PromptScrollGeometry(layout: layout, viewport: 100, placement: .centered)
        XCTAssertEqual(g.lineAtGuide(offset: stage.offset), layout.lineIndex(ofWord: word))
        XCTAssertEqual(stage.cachedLayoutCount, 2)
        stage.setViewport(CGSize(width: 148, height: 100))
        XCTAssertEqual(stage.cachedLayoutCount, 2, "back to the first width: from the cache")
        rig.session.stop()
    }

    // MARK: - Motion (10.3)

    /// The spec's curves, and Reduce Motion replaces every one with an
    /// immediate move.
    func testEveryScrollIsImmediateUnderReduceMotion() {
        XCTAssertEqual(PrompterStageMotion.timer.duration, 0.06)
        XCTAssertEqual(PrompterStageMotion.follow.duration, 0.5)
        XCTAssertEqual(PrompterStageMotion.manual.duration, 0.15)
        XCTAssertEqual(PrompterStageMotion.readingPosition.duration, 0.28)
        XCTAssertNil(PrompterStageMotion.cut.duration)
        for motion in PrompterStageMotion.allCases {
            XCTAssertNil(motion.animation(reduceMotion: true), "\(motion) under Reduce Motion")
        }
        XCTAssertNotNil(PrompterStageMotion.timer.animation(reduceMotion: false))
    }

    /// The reading position changed in Settings moves the text over 0.28 s,
    /// backward if it has to, without arming anything for the clock.
    func testAReadingPositionChangeReanchorsSmoothly() {
        let rig = StageRig()
        let stage = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript(twelve)]))
        stage.setViewport(CGSize(width: 148, height: 100))
        rig.read(for: 3.05)
        let centered = stage.offset
        rig.settings.readingPosition = .nearTop
        XCTAssertEqual(stage.motion, .readingPosition)
        XCTAssertNotEqual(stage.offset, centered)
        rig.session.stop()
    }
}

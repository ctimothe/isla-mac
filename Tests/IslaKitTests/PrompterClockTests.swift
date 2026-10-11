import Foundation
import XCTest
@testable import IslaKit

/// `PromptClock` is the Classic (and later Voice) progress clock of spec 8.1:
/// `p += speed * min(dt, 0.25)` per tick, in fractional words. It is a pure
/// value driven by the times it is handed, so nothing here waits on a real
/// timer or reads the wall clock.
final class PrompterClockTests: XCTestCase {
    private let accuracy = 1e-9

    private func clock(_ text: String, speed: Double = 1) -> PromptClock {
        PromptClock(script: PromptScript(text), speed: speed)
    }

    // MARK: - Speed

    func testDefaultSpeedIsThreeWordsPerSecond() {
        XCTAssertEqual(PromptClock.defaultSpeed, 3.0)
        XCTAssertEqual(PromptClock(script: PromptScript("a b")).speed, 3.0)
    }

    func testSpeedIsClampedToTheSpecRange() {
        XCTAssertEqual(PromptClock.clampedSpeed(0), 0.5)
        XCTAssertEqual(PromptClock.clampedSpeed(-4), 0.5)
        XCTAssertEqual(PromptClock.clampedSpeed(0.5), 0.5)
        XCTAssertEqual(PromptClock.clampedSpeed(8), 8)
        XCTAssertEqual(PromptClock.clampedSpeed(9.5), 8)
        XCTAssertEqual(PromptClock.clampedSpeed(1_000_000), 8)
    }

    func testSpeedSnapsToHalfWordSteps() {
        XCTAssertEqual(PromptClock.clampedSpeed(2.74), 2.5)
        XCTAssertEqual(PromptClock.clampedSpeed(2.76), 3.0)
        XCTAssertEqual(PromptClock.clampedSpeed(7.9), 8.0)
    }

    /// A NaN in a hand-edited plist once overflowed the stack in the old
    /// store; the clock treats any non-finite speed as the default.
    func testNonFiniteSpeedFallsBackToTheDefault() {
        XCTAssertEqual(PromptClock.clampedSpeed(.nan), 3.0)
        XCTAssertEqual(PromptClock.clampedSpeed(.infinity), 3.0)
        XCTAssertEqual(PromptClock.clampedSpeed(-.infinity), 3.0)
        XCTAssertEqual(PromptClock(script: PromptScript("a"), speed: .nan).speed, 3.0)
    }

    func testSpeedChangeAppliesToARunningClock() {
        var c = clock("a b c d e f g h i j k l", speed: 1)
        c.start(at: 0)
        c.tick(at: 0.2)
        XCTAssertEqual(c.progress, 0.2, accuracy: accuracy)
        c.setSpeed(4)
        XCTAssertTrue(c.isRunning)
        c.tick(at: 0.4)
        XCTAssertEqual(c.progress, 0.2 + 0.8, accuracy: accuracy)
    }

    // MARK: - Ticking

    func testTickAddsSpeedTimesElapsedTime() {
        var c = clock("a b c d e f g h", speed: 2)
        c.start(at: 100)
        XCTAssertTrue(c.tick(at: 100.05))
        XCTAssertEqual(c.progress, 0.1, accuracy: accuracy)
        c.tick(at: 100.10)
        XCTAssertEqual(c.progress, 0.2, accuracy: accuracy)
    }

    /// A long stall (sleep, a blocked main thread) must not jump the text:
    /// one tick never adds more than a quarter second of reading.
    func testElapsedTimeIsCappedAtAQuarterSecond() {
        var c = clock("a b c d e f g h i j", speed: 4)
        c.start(at: 0)
        c.tick(at: 30)
        XCTAssertEqual(c.progress, 1.0, accuracy: accuracy)
        XCTAssertEqual(PromptClock.maxStep, 0.25)
    }

    func testCapAppliesExactlyAtTheBoundary() {
        var c = clock("a b c d e f g h i j", speed: 1)
        c.start(at: 0)
        c.tick(at: 0.25)
        XCTAssertEqual(c.progress, 0.25, accuracy: accuracy)
        c.tick(at: 0.51)
        XCTAssertEqual(c.progress, 0.50, accuracy: accuracy)
    }

    func testTickIntervalIsTwentyHertz() {
        XCTAssertEqual(PromptClock.tickInterval, 0.05)
    }

    func testAStoppedClockDoesNotAdvance() {
        var c = clock("a b c", speed: 3)
        XCTAssertFalse(c.isRunning)
        XCTAssertFalse(c.tick(at: 5))
        XCTAssertEqual(c.progress, 0)
    }

    /// Pause and resume: the time spent paused is not read. Resuming sets a
    /// fresh baseline, so the first tick after it counts only from the resume.
    func testPauseAndResumeDoNotCountThePausedTime() {
        var c = clock("a b c d e f g h", speed: 1)
        c.start(at: 0)
        c.tick(at: 0.2)
        c.stop()
        XCTAssertFalse(c.isRunning)
        XCTAssertFalse(c.tick(at: 0.25))
        c.start(at: 10)
        c.tick(at: 10.1)
        XCTAssertEqual(c.progress, 0.3, accuracy: accuracy)
    }

    func testStartingARunningClockKeepsItsBaseline() {
        var c = clock("a b c d e f g h", speed: 1)
        c.start(at: 0)
        c.start(at: 0.1)
        c.tick(at: 0.2)
        XCTAssertEqual(c.progress, 0.2, accuracy: accuracy)
    }

    func testTimeRunningBackwardsDoesNotRewindTheText() {
        var c = clock("a b c d e f g h", speed: 1)
        c.start(at: 10)
        c.tick(at: 10.2)
        c.tick(at: 9)
        XCTAssertEqual(c.progress, 0.2, accuracy: accuracy)
        // The baseline followed the clock back, so the next tick is sane.
        c.tick(at: 9.1)
        XCTAssertEqual(c.progress, 0.3, accuracy: accuracy)
    }

    func testNonFiniteTimeIsIgnored() {
        var c = clock("a b c d", speed: 1)
        c.start(at: 0)
        XCTAssertFalse(c.tick(at: .nan))
        XCTAssertFalse(c.tick(at: .infinity))
        c.tick(at: 0.1)
        XCTAssertEqual(c.progress, 0.1, accuracy: accuracy)
    }

    // MARK: - End

    func testProgressClampsAtTheWordCountAndReportsTheEnd() {
        var c = clock("one two", speed: 8)
        c.start(at: 0)
        c.tick(at: 0.25)
        XCTAssertEqual(c.progress, 2, accuracy: accuracy)
        XCTAssertTrue(c.isAtEnd)
        XCTAssertNil(c.currentWordIndex)
        XCTAssertFalse(c.tick(at: 0.5))
        XCTAssertEqual(c.progress, 2)
    }

    func testAnEmptyPageIsAtItsEnd() {
        let c = clock("   \n  ")
        XCTAssertEqual(c.wordCount, 0)
        XCTAssertTrue(c.isAtEnd)
    }

    /// E-21: a page with only cues or only punctuation finishes at once
    /// instead of waiting a word's time per cue.
    func testACueOrPunctuationOnlyPageIsAtItsEndImmediately() {
        XCTAssertTrue(clock("[smile] [pause]").isAtEnd)
        XCTAssertTrue(clock("-- ... •").isAtEnd)
        XCTAssertTrue(clock("[look at camera] —").isAtEnd)
    }

    // MARK: - Cues and non-speech tokens

    func testALeadingCueIsSkippedBeforeTheFirstTick() {
        let c = clock("[smile] hello world")
        XCTAssertEqual(c.progress, 1)
        XCTAssertEqual(c.currentWordIndex, 1)
    }

    /// A cue is shown, never spoken: progress passes over it without spending
    /// reading time on it.
    func testCuesAndNonSpeechTokensCostNoTime() {
        // words: one [smile] -- two three
        var c = clock("one [smile] -- two three", speed: 1)
        c.start(at: 0)
        for t in stride(from: 0.25, through: 1.0, by: 0.25) { c.tick(at: t) }
        XCTAssertEqual(c.progress, 3, accuracy: accuracy)
        XCTAssertEqual(c.currentWordIndex, 3)
        c.tick(at: 1.25)
        XCTAssertEqual(c.progress, 3.25, accuracy: accuracy)
    }

    func testOneTickCanCrossACueInTheMiddleOfItsStep() {
        // words: a [x] b c ; speed 8, one capped tick reads two words.
        var c = clock("a [x] b c", speed: 8)
        c.start(at: 0)
        c.tick(at: 0.25)
        XCTAssertEqual(c.progress, 3, accuracy: accuracy)
    }

    func testTrailingCuesFinishWithTheLastSpokenWord() {
        var c = clock("hello [smile]", speed: 4)
        c.start(at: 0)
        c.tick(at: 0.25)
        XCTAssertTrue(c.isAtEnd)
        XCTAssertEqual(c.progress, 2)
    }

    // MARK: - Words and jumps

    func testCurrentWordAndFraction() {
        var c = clock("alpha beta gamma", speed: 2)
        c.start(at: 0)
        c.tick(at: 0.15)
        c.tick(at: 0.3)
        XCTAssertEqual(c.currentWordIndex, 0)
        XCTAssertEqual(c.fraction, 0.6, accuracy: accuracy)
        c.tick(at: 0.55)
        XCTAssertEqual(c.currentWordIndex, 1)
        XCTAssertEqual(c.fraction, 0.1, accuracy: accuracy)
    }

    func testJumpSetsProgressToTheStartOfTheWord() {
        var c = clock("a b c d", speed: 1)
        c.jump(toWord: 2)
        XCTAssertEqual(c.progress, 2)
    }

    func testJumpIsClampedAndMovesPastACue() {
        var c = clock("a [x] [y] b", speed: 1)
        c.jump(toWord: 1)
        XCTAssertEqual(c.progress, 3)
        c.jump(toWord: -5)
        XCTAssertEqual(c.progress, 0)
        c.jump(toWord: 99)
        XCTAssertEqual(c.progress, 4)
        XCTAssertTrue(c.isAtEnd)
    }

    func testJumpOnARunningClockKeepsItsBaseline() {
        var c = clock("a b c d e f", speed: 1)
        c.start(at: 0)
        c.tick(at: 0.1)
        c.jump(toWord: 3)
        c.tick(at: 0.2)
        XCTAssertEqual(c.progress, 3.1, accuracy: accuracy)
    }
}

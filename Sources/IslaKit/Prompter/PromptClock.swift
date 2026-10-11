import Foundation

// Foundation only, like `PromptScript`: the clock is a pure value that is
// handed the time instead of reading it, so a test can drive a whole session
// in microseconds and no test ever waits on a real timer.

/// The Classic progress clock of spec 8.1 (and, gated by a speaking flag, the
/// Voice clock of 8.2 later). Progress is fractional words, `0...wordCount`,
/// over *every* word of the page including cues and non-speech tokens, because
/// that is the unit the stage interpolates in (10.3: between the midpoints of
/// the active and the next word by the fractional progress).
///
/// Cues and non-speech tokens cost no reading time: progress jumps over them
/// whole. Without that a page of `[smile] [pause]` would sit for two words'
/// time doing nothing (E-21 requires it to finish at once), and a `--` in the
/// middle of a sentence would hold the text still for a third of a second at
/// the default speed.
struct PromptClock: Sendable, Equatable {
    static let speedRange: ClosedRange<Double> = 0.5...8
    static let speedStep = 0.5
    /// A starting value, to be calibrated on hardware; ordinary speech is
    /// about 2 to 2.7 words per second.
    static let defaultSpeed = 3.0
    /// The longest stretch of time one tick may read. A sleep, a blocked main
    /// thread or a debugger pause would otherwise jump the text by however
    /// long the stall lasted.
    static let maxStep: TimeInterval = 0.25
    /// 20 Hz. The session's timer runs at this interval while `running`.
    static let tickInterval: TimeInterval = 0.05

    /// One flag per word: true for a cue or a non-speech token.
    private let skipped: [Bool]
    private(set) var progress: Double
    private(set) var speed: Double
    /// The time of the previous tick; nil while the clock is stopped. Keeping
    /// the baseline here, rather than in the timer, is what makes a resume
    /// count only from the resume: stopping drops it, starting sets it fresh.
    private(set) var lastTick: TimeInterval?

    init(script: PromptScript, speed: Double = PromptClock.defaultSpeed) {
        skipped = script.words.map(\.isSkipped)
        self.speed = Self.clampedSpeed(speed)
        progress = 0
        moveOffSkippedWords()
    }

    var wordCount: Int { skipped.count }
    var isRunning: Bool { lastTick != nil }
    var isAtEnd: Bool { progress >= Double(wordCount) }

    /// The word being read, nil at the end. Never a cue or a non-speech token
    /// while the clock is the only thing that has moved progress.
    var currentWordIndex: Int? { isAtEnd ? nil : Int(progress) }

    /// How far into the current word, `0..<1`; 0 at the end.
    var fraction: Double { isAtEnd ? 0 : progress - progress.rounded(.down) }

    // MARK: - Speed

    /// Clamped to 0.5...8 and snapped to the stepper's 0.5 words per second,
    /// so a value the hot keys or the stepper produce and one a hand-edited
    /// plist produces land on the same grid. Non-finite is the default: a NaN
    /// in a hand-edited plist once overflowed the stack in the old store.
    static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpeed }
        let snapped = (value / speedStep).rounded() * speedStep
        return min(max(snapped, speedRange.lowerBound), speedRange.upperBound)
    }

    /// Applies to a running clock from the next tick (spec 8.1).
    mutating func setSpeed(_ value: Double) {
        speed = Self.clampedSpeed(value)
    }

    // MARK: - Running

    /// Starts reading from `now`. Starting a clock that already runs keeps the
    /// old baseline, so a redundant start cannot swallow the time since the
    /// last tick.
    mutating func start(at now: TimeInterval) {
        guard lastTick == nil, now.isFinite else { return }
        lastTick = now
    }

    mutating func stop() {
        lastTick = nil
    }

    /// Adds `speed * min(dt, 0.25)` words. Returns whether progress moved.
    /// Time that runs backwards (a fake clock, a monotonic source swapped
    /// under us) reads nothing and re-bases, rather than rewinding the text.
    @discardableResult
    mutating func tick(at now: TimeInterval) -> Bool {
        guard let last = lastTick, now.isFinite else { return false }
        lastTick = now
        let dt = min(max(now - last, 0), Self.maxStep)
        guard dt > 0, !isAtEnd else { return false }
        let before = progress
        advance(by: speed * dt)
        return progress != before
    }

    /// Sets progress to the start of `word`, clamped to the page and moved
    /// past any cue or non-speech run it lands on (spec 8.5, timer modes). The
    /// running state and its baseline are kept: a tap is not a pause.
    mutating func jump(toWord word: Int) {
        progress = Double(min(max(word, 0), wordCount))
        moveOffSkippedWords()
    }

    // MARK: - Private

    /// Walks the reading budget word by word so a skipped word inside one
    /// step costs nothing, then lands any remainder inside the next spoken
    /// word. Word boundaries are set exactly, never accumulated, so a long
    /// read cannot drift onto the wrong side of a boundary.
    private mutating func advance(by words: Double) {
        var remaining = words
        let end = Double(wordCount)
        while remaining > 0, progress < end {
            let index = Int(progress)
            let room = Double(index + 1) - progress
            if remaining < room {
                progress += remaining
                return
            }
            progress = Double(index + 1)
            remaining -= room
            moveOffSkippedWords()
        }
        progress = min(progress, end)
    }

    /// From the start of a skipped word, on to the start of the next spoken
    /// one or to the end.
    private mutating func moveOffSkippedWords() {
        var index = Int(progress)
        guard index < wordCount, skipped[index] else { return }
        while index < wordCount, skipped[index] { index += 1 }
        progress = Double(index)
    }
}

import Foundation

// Foundation only. What the stage says about where reading stands: the state
// each word is drawn in (spec 10.1), the elapsed readout (ruling 20.4), what
// VoiceOver hears (15), and the sentences a state change announces.

// MARK: - Word states (10.1)

enum PrompterWordState: Sendable, Equatable {
    case unread
    /// The next spoken word not yet fully read. Underlined, never dimmed.
    case current
    case read
    /// Inside `[...]`. One look whatever the reading position: a note to the
    /// speaker is neither ahead nor behind (T7 design note, cue ladder).
    case cue
}

extension PrompterGuidanceMode {
    /// Classic, and Voice in release 2: progress is a clock's smooth fraction,
    /// and the page glides between word midpoints (10.3). Follow (release 3)
    /// is not: it moves to the recognized word. A new mode has to answer here;
    /// the switch has no default.
    var isTimerMode: Bool {
        switch self {
        case .classic: return true
        }
    }

    /// Timer modes draw every word alike: their progress is a fraction the
    /// speaker does not follow word by word, so a moving read edge would only
    /// race the voice. Follow draws read, current and unread (10.1).
    var drawsUniformly: Bool { isTimerMode }
}

enum PromptWordStates {
    /// The current word for a progress value: the word progress is in, or the
    /// next one after it that is spoken. A cue or a non-speech token (`--`, an
    /// emoji) is never current; nil at the end of the page.
    static func currentWord(in script: PromptScript, progress: Double) -> Int? {
        let count = script.words.count
        guard progress.isFinite, progress < Double(count) else { return nil }
        var index = max(0, Int(progress))
        while index < count, script.words[index].isSkipped { index += 1 }
        return index < count ? index : nil
    }

    static func state(of index: Int, in script: PromptScript, progress: Double, uniform: Bool) -> PrompterWordState {
        state(of: index, in: script, current: currentWord(in: script, progress: progress),
              atEnd: progress >= Double(script.words.count), uniform: uniform)
    }

    /// The per-word half, for a renderer that found `current` once per frame
    /// rather than once per word.
    static func state(
        of index: Int, in script: PromptScript, current: Int?, atEnd: Bool, uniform: Bool
    ) -> PrompterWordState {
        if script.words[index].isCue { return .cue }
        if uniform { return .unread }
        guard let current else { return atEnd ? .read : .unread }
        if index == current { return .current }
        return index < current ? .read : .unread
    }
}

// MARK: - Elapsed (ruling 20.4)

/// How long the speaker has been reading in this session: running time only.
/// Pauses (the user's, the lock's, sleep's), `finished` and a countdown are
/// not counted, so the readout is the length of the talk as delivered, and a
/// coffee break with the session paused does not land in it. Time comes in
/// from the session's own clock, so a test never waits.
struct PromptElapsed: Sendable, Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: TimeInterval?

    mutating func run(at now: TimeInterval) {
        guard runningSince == nil, now.isFinite else { return }
        runningSince = now
    }

    mutating func halt(at now: TimeInterval) {
        guard let since = runningSince else { return }
        if now.isFinite { accumulated += max(0, now - since) }
        runningSince = nil
    }

    mutating func reset() {
        accumulated = 0
        runningSince = nil
    }

    func value(at now: TimeInterval) -> TimeInterval {
        guard let since = runningSince, now.isFinite else { return accumulated }
        return accumulated + max(0, now - since)
    }
}

// MARK: - What the stage says (15)

enum PrompterStageSpeech {
    /// The sentence a state change is announced with, or nil for none.
    ///
    /// Start is said by the start itself ("Prompter started", in
    /// `NotchViewModel.beginSession`), so it is not said twice here. Lock and
    /// sleep pause the session behind a lock screen or a dark display, where
    /// the lock is the news. The end of a page is said once per arrival
    /// ("completion announces once"), as the end of the script when there is
    /// no page after it.
    static func announcement(
        from old: PrompterSessionState, to new: PrompterSessionState, hasNextPage: Bool
    ) -> String? {
        guard old != new else { return nil }
        switch (old, new) {
        case (.running, .paused(.user)), (.finished, .paused(.user)):
            return localized("Prompter paused")
        case (.paused, .running):
            return localized("Prompter resumed")
        case (_, .finished):
            return hasNextPage ? localized("End of page") : localized("End of script")
        case (_, .ended) where old.isLive:
            return localized("Prompter stopped")
        default:
            return nil
        }
    }

    /// The text region's accessibility value: the line being read and how far
    /// through the page reading is, as a percentage. One element for the page
    /// rather than one per word: a script of a thousand words is not a
    /// thousand stops (15).
    static func accessibilityValue(script: PromptScript?, layout: PromptLayout?, progress: Double) -> String {
        guard let script, !script.words.isEmpty else { return "" }
        let count = Double(script.words.count)
        let clamped = progress.isFinite ? min(max(progress, 0), count) : 0
        let percent = Int((clamped / count * 100).rounded(.down))
        let word = PromptWordStates.currentWord(in: script, progress: clamped)
            ?? script.words.count - 1
        let line: String
        if let layout, let index = layout.lineIndex(ofWord: word), layout.isComplete || word < layout.lineOfWord.count {
            line = layout.text(ofLine: index, in: script)
        } else {
            line = script.words[word].text
        }
        return localized("%@, %d%%", line, percent)
    }
}

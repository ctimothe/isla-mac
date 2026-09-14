import Foundation

/// Copy and interaction policy shared by every lyric surface. Views render a
/// concrete availability state; they never treat missing lines as a status.
enum LyricsPresentation {
    static func compactCaption(
        for availability: LyricsAvailability,
        currentLine: String?,
        localLookup: LocalLyricsLookup? = nil
    ) -> String {
        if case .noLocalLyrics = availability, case .ambiguous = localLookup {
            return localized("Choose local lyrics…")
        }
        switch availability {
        case .disabled:
            return localized("Lyrics are switched off in Settings.")
        case .settlingPlayback:
            return localized("Syncing playback…")
        case .findingLocalLyrics:
            return localized("Finding lyrics…")
        case .ready:
            return currentLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? currentLine!
                : localized("Finding lyrics…")
        case .noLocalLyrics:
            return localized("No lyrics for this track.")
        case .invalidLocalFile:
            return localized("No lyrics for this track.")
        }
    }

    static func canRetry(_ availability: LyricsAvailability) -> Bool {
        switch availability {
        case .ready: return true
        case .noLocalLyrics, .invalidLocalFile: return true
        default: return false
        }
    }

    static func canOpenLocalActions(_ availability: LyricsAvailability) -> Bool {
        switch availability {
        case .noLocalLyrics, .invalidLocalFile: return true
        default: return false
        }
    }

    static func usesWordTiming(
        _ granularity: LyricTimeline.Granularity?,
        precisionMeasured: Bool
    ) -> Bool {
        granularity == .word && precisionMeasured
    }
}

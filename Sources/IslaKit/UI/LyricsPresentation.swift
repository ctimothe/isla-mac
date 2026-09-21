import Foundation

/// Copy and interaction policy shared by every lyric surface. Views render a
/// concrete availability state; they never treat missing lines as a status.
enum LyricsPresentation {
    /// - Parameter onlineEnabled: whether LRCLIB was asked as well. With it
    ///   on, "No local lyrics." undersold the search — it read as though the
    ///   catalogue had never been tried — so the miss says nothing was found.
    static func compactCaption(
        for availability: LyricsAvailability,
        currentLine: String?,
        localLookup: LocalLyricsLookup? = nil,
        onlineEnabled: Bool = false
    ) -> String {
        if case .noLocalLyrics = availability, case .ambiguous = localLookup {
            return localized("Choose local lyrics…")
        }
        switch availability {
        case .disabled:
            return localized("Lyrics are switched off in Settings.")
        case .resolving:
            // Deliberately empty: the slot holds its height and fills when the
            // answer lands, so a fast one never shows a loading state.
            return ""
        case .findingLocalLyrics:
            return localized("Finding lyrics…")
        case .ready:
            return currentLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? currentLine!
                : localized("Finding lyrics…")
        case .noLocalLyrics:
            return onlineEnabled ? localized("No lyrics found.") : localized("No local lyrics.")
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
        precisionMeasured: Bool,
        wordKaraokeEnabled: Bool
    ) -> Bool {
        wordKaraokeEnabled && granularity == .word && precisionMeasured
    }
}

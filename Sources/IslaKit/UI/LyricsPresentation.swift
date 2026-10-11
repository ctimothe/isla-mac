import Foundation

/// Copy and interaction policy shared by every lyric surface. Views render a
/// concrete availability state; they never treat missing lines as a status.
enum LyricsPresentation {
    /// - Parameter onlineEnabled: whether LRCLIB was asked as well. With it
    ///   on, a miss says nothing was found for the song; with it off, it says
    ///   where the search looked, so it never reads as though the catalogue
    ///   had been tried. "No local lyrics." said the second in jargon a new
    ///   listener met on nearly every song, beside three other miss strings
    ///   with no common voice; each miss now names its reason in plain words.
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
            // The page under this caption now offers the switch itself.
            return localized("Lyrics are off.")
        case .cannotLookUp(.noLength):
            // Not "off": the switch is on, and saying otherwise sent people to
            // a Show Lyrics button that could not help a stream.
            return localized("No lyrics for live audio.")
        case .cannotLookUp(.noTitle):
            return localized("This track has no title to look up.")
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
            // "This Mac" matches Settings' "Lyrics stay on this Mac.", and the
            // stage still offers Look Up Online beside it.
            return onlineEnabled
                ? localized("No lyrics found for this song.")
                : localized("No lyrics on this Mac.")
        case .invalidLocalFile:
            // There is a file, and it is the problem. "No lyrics for this
            // track." hid that behind the same words as a miss.
            return localized("Can't read the lyrics file for this song.")
        }
    }

    /// The one action an empty lyrics page offers, if any.
    enum Offer: Equatable {
        /// Lyrics are off: turn them on, which reaches nothing but this Mac.
        case turnOnLyrics
        /// Nothing local matched and LRCLIB was never asked: ask it, with
        /// the disclosure beside the button.
        case lookUpOnline
    }

    static func offer(
        for availability: LyricsAvailability,
        localLookup: LocalLyricsLookup?,
        onlineEnabled: Bool
    ) -> Offer? {
        switch availability {
        case .disabled:
            return .turnOnLyrics
        case .noLocalLyrics:
            // An ambiguous match already has its own choice on the page.
            if case .ambiguous = localLookup { return nil }
            return onlineEnabled ? nil : .lookUpOnline
        case .cannotLookUp:
            // Nothing to offer. Show Lyrics is already on, and Look Up Online
            // cannot identify a recording with no length or no title.
            return nil
        default:
            return nil
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

import Foundation

/// Copy and interaction policy shared by every lyric surface. Views render a
/// concrete availability state; they never treat missing lines as a status.
enum LyricsPresentation {
    static func compactCaption(for availability: LyricsAvailability, currentLine: String?) -> String {
        switch availability {
        case .disabled:
            return localized("Lyrics are switched off in Settings.")
        case .settlingPlayback:
            return localized("Syncing playback…")
        case .resolving:
            return localized("Finding lyrics…")
        case .ready:
            return currentLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? currentLine!
                : localized("Finding lyrics…")
        case .unavailable:
            return localized("No lyrics for this track.")
        case .failed(let failure):
            switch failure.kind {
            case .connection: return localized("Lyrics connection failed.")
            case .rateLimited: return localized("Lyrics are temporarily rate limited.")
            case .service: return localized("Lyrics service is unavailable.")
            }
        }
    }

    static func canRetry(_ availability: LyricsAvailability) -> Bool {
        switch availability {
        case .ready: return true
        case .unavailable: return true
        case .failed(let failure): return failure.retryable
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

import CoreGraphics

/// The persistent, collapsed Now Playing state around the physical notch.
///
/// Kept separate from the expanded panel and from transport commands so a
/// player update can change the glanceable presentation without changing what
/// a rapid play/pause sequence means.
enum CompactMediaActivity: Equatable {
    case hidden
    case paused
    case playing

    init(hasTrack: Bool, isPlaying: Bool) {
        guard hasTrack else {
            self = .hidden
            return
        }
        self = isPlaying ? .playing : .paused
    }

    var isVisible: Bool { self != .hidden }
    var animatesEqualizer: Bool { self == .playing }
    var showsArtworkPlayBadge: Bool { self == .paused }

    /// - Parameter peeking: whether a new track is showing itself. The pill
    ///   widens for that moment so the title has somewhere to go, then returns
    ///   to the width the artwork and equalizer need on their own.
    func bodySize(notchSize: CGSize, peeking: Bool = false) -> CGSize {
        guard isVisible else { return notchSize }
        let extension_ = peeking
            ? NotchMetrics.sneakPeekExtension
            : NotchMetrics.compactMediaExtension
        return CGSize(
            width: min(notchSize.width + extension_, NotchMetrics.standardBody.width),
            height: notchSize.height
        )
    }
}

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

    /// - Parameter pauseHasSettled: the track has been paused long enough that
    ///   it is no longer "just paused" — see `NotchMetrics.pausedLinger`. A
    ///   paused island used to stay drawn for as long as the player kept a
    ///   track loaded, which for Spotify is forever: an idle Mac with nothing
    ///   playing still carried a pill, a placeholder cover and a still
    ///   equalizer across its menu bar. Now a settled pause folds into the
    ///   notch, the same as nothing loaded at all.
    init(hasTrack: Bool, isPlaying: Bool, pauseHasSettled: Bool = false) {
        guard hasTrack else {
            self = .hidden
            return
        }
        if isPlaying {
            self = .playing
        } else {
            self = pauseHasSettled ? .hidden : .paused
        }
    }

    var isVisible: Bool { self != .hidden }
    var animatesEqualizer: Bool { self == .playing }
    var showsArtworkPlayBadge: Bool { self == .paused }

    /// - Parameter peeking: whether a new track is showing itself. The pill
    ///   widens for that moment so the title has somewhere to go, then returns
    ///   to the width the artwork and equalizer need on their own.
    /// - Parameter bodyWidth: the expanded body's width, which the pill may
    ///   never outgrow. Passed rather than read, so the arithmetic stays pure and
    ///   the tests can state a width instead of writing a default.
    func bodySize(
        notchSize: CGSize,
        peeking: Bool = false,
        bodyWidth: CGFloat = NotchMetrics.defaultBodyWidth
    ) -> CGSize {
        guard isVisible else { return notchSize }
        let extension_ = peeking
            ? NotchMetrics.sneakPeekExtension
            : NotchMetrics.compactMediaExtension
        return CGSize(
            width: min(notchSize.width + extension_, bodyWidth),
            height: notchSize.height
        )
    }
}

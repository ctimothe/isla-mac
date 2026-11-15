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
    /// Playing draws the equalizer in the cover's tint; paused draws it at rest
    /// in tertiary, so the one colour on the island is the one that is moving
    /// (spec §3.2).
    var tintsEqualizer: Bool { self == .playing }

    /// The pill: the notch and `compactMediaExtension`, at the notch's
    /// height. A new track no longer widens it (spec §3.5, amended
    /// 2026-11-15): it shows as the pop-up does, and the pill waits faded
    /// under it.
    /// - Parameter bodyWidth: the expanded body's width, which the pill may
    ///   never outgrow. Passed rather than read, so the arithmetic stays pure and
    ///   the tests can state a width instead of writing a default.
    func bodySize(
        notchSize: CGSize,
        bodyWidth: CGFloat = NotchMetrics.defaultBodyWidth
    ) -> CGSize {
        guard isVisible else { return notchSize }
        return CGSize(
            width: min(notchSize.width + NotchMetrics.compactMediaExtension, bodyWidth),
            height: notchSize.height
        )
    }
}

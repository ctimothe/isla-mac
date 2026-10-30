import Observation
import SwiftUI

/// The playing position, on its own (Batch 18, 2026-10-29).
///
/// While the player, the stage or the lock card is up the position ticks ten
/// times a second. It was `@Published` on `MediaController`, so every tick
/// announced a change of the whole controller and every view watching it ran
/// its body again: the player's cover, title, transport and their tooltips,
/// to move a bar and two labels. Open on the player and left alone, the
/// running Isla spent 6.9 % of a core on that (B17-H1). Observation tracks
/// what a body actually reads, so a tick now reaches the views that draw the
/// position and no others. `MediaController.position` reads and writes it;
/// nothing else should.
@MainActor @Observable
final class PlaybackClock {
    var position: TimeInterval = 0
}

/// The part of a view that draws the position, set apart so that a tick
/// re-runs this and not the view around it. Its content is laid out in the
/// parent's container as if it were written there.
struct ClockReader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// The song's clock as a straight line (Batch 19, 2026-10-30): where the media
/// clock puts the song at any monotonic moment, given one reading of it.
///
/// `MediaController.extrapolatedPosition` runs this arithmetic and nothing
/// else, so a surface holding a `SongClock` and a surface asking the
/// controller are on one clock. It exists so the word sweep can hand Core
/// Animation the whole of a line in advance instead of asking for the clock
/// on every display frame, which laid out and rendered the panel 120 times a
/// second (B18-H1).
struct SongClock: Equatable, Sendable {
    /// The song's position at `atMono`, with whatever lead the surface added.
    var position: TimeInterval
    var atMono: TimeInterval
    var rate: Double
    /// Where the song stops, the track's end with the same lead; nil for a
    /// track of unknown length.
    var cap: TimeInterval?

    /// The machine's monotonic clock: `MediaController.monotonicNow` in the
    /// app, and the clock Core Animation's media time is read from, so a
    /// moment on one is a moment on the other.
    static let hostNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func position(at mono: TimeInterval) -> TimeInterval {
        let value = position + (mono - atMono) * rate
        return cap.map { min(value, $0) } ?? value
    }

    /// When the song reaches `song`; nil when it never will — a still or
    /// reversed rate, or a moment past the end.
    func mono(atSong song: TimeInterval) -> TimeInterval? {
        guard rate > 0 else { return nil }
        if let cap, song > cap { return nil }
        return atMono + (song - position) / rate
    }

    func leading(_ lead: TimeInterval) -> SongClock {
        SongClock(position: position + lead, atMono: atMono, rate: rate, cap: cap.map { $0 + lead })
    }

    /// Whether `other` is this line read at another moment: the same rate
    /// and end, and the song within `tolerance` of where this one puts it.
    /// The 0.1 s tick hands the sweep a new reading every time, and a fresh
    /// reading of an unchanged clock must not restart an animation that is
    /// already right; a correction past a few milliseconds must.
    func agrees(with other: SongClock, within tolerance: TimeInterval = 0.002) -> Bool {
        guard rate == other.rate, cap == other.cap else { return false }
        let theirs = other.position + (atMono - other.atMono) * other.rate
        return abs(theirs - position) <= tolerance
    }
}

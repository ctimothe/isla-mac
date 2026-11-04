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

    /// What the time labels show, in whole seconds (Batch 20, 2026-10-30).
    ///
    /// The labels read `position` in a `ClockReader`, so every tick re-ran
    /// them to draw the same two strings nine times out of ten, and a pass of
    /// the panel's graph, layout and render came with each one. These change
    /// only when a label's text does: at most twice a second, once for each
    /// label, since the remaining time turns on the track's fraction of a
    /// second and the elapsed time on the whole one.
    var seconds = Seconds()

    /// How the bar moves: still at a position, or along the song's clock.
    /// Changes on a seek, a pause, a new rate or a correction, never on a
    /// tick, so the fill Core Animation draws from it is handed nothing
    /// between them (`PlaybackFill`).
    var motion: Motion = .still(0)

    /// Where the player's sung line reads the song (Batch 21, 2026-10-30):
    /// the position as it stood when it last crossed a lyric boundary or the
    /// clock last changed course, left behind between those.
    ///
    /// The line read `position` in a `ClockReader`, and the tick re-ran it ten
    /// times a second to draw the line already drawn: SwiftUI rebuilt its
    /// text, laid the panel out and rebuilt the key-view loop each time, 7.2 %
    /// of a core open on the player with a line-timed song against 1.9 % with
    /// the band off (B20-H1). What the line draws turns only where a line
    /// starts, where its voice ends and where the caption reads ahead, which
    /// are the boundaries the clock already wakes on
    /// (`MediaController.setLyricBoundaries`), so read here it is the line
    /// the position would have drawn. A word sweep's edge does not read this:
    /// Core Animation moves it from `motion`.
    var linePosition: TimeInterval = 0

    /// The lead `linePosition` was kept against, asked of the lyrics on
    /// every change of the clock. A Lyric Delay or a track's nudge reaches
    /// the pane at once, through the store, and the clock only on its next
    /// tick: until then a reading kept at a line's turn, read with the new
    /// lead, can name the line before it. A surface whose lead is not this
    /// one reads the position instead (`shownLinePosition`).
    var lineLead: TimeInterval = 0

    struct Seconds: Equatable {
        var elapsed = 0
        var remaining = 0

        /// The two labels for `shown` seconds of a `duration`-second song:
        /// `formatTime` rounds, so these round the same way and the labels
        /// drawn from them are the ones drawn from the exact time. A reading
        /// that is not a number, or is below zero by any amount, draws "--:--"
        /// as it always did, which a rounded zero would not. So does one past
        /// a billion seconds: these are worked out on every change of the
        /// clock, the panel shut included, and `Int(_:)` traps past
        /// `Int.max`, so a stream's sentinel length must never reach it.
        init(shown: TimeInterval, duration: TimeInterval) {
            elapsed = Self.whole(shown)
            remaining = Self.whole(max(0, duration - shown))
        }

        init() {}

        private static func whole(_ seconds: TimeInterval) -> Int {
            seconds.isFinite && seconds >= 0 && seconds < 1e9 ? Int(seconds.rounded()) : -1
        }
    }

    enum Motion: Equatable {
        case still(TimeInterval)
        case moving(SongClock)
    }
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

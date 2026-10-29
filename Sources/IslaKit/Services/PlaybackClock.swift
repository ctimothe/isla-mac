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

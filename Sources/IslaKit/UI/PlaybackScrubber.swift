import SwiftUI

/// The playback bar: a track, its fill, a dot under the pointer, drag-to-seek
/// and the slider VoiceOver hears — one view for the player and for the lyrics
/// stage's foot.
///
/// The stage's bar was drawn and nothing else: "you cannot swipe this bottom
/// progress bar left or right" (owner, 2026-10-24), and its old comment said the
/// player's bar was the one to seek with. A lyrics page is where a song is
/// listened to closely, and the one place a person wants to move back to a line
/// they missed. So it is the player's scrubber rather than a second one: the
/// same hover dot, the same time preview, the same drag, the same accessibility.
/// What differs is only the look — the track and fill colours and the bar's
/// height — which the caller passes.
///
/// A drag here is a mouse drag on this view and nothing else's. `PageSwipe` only
/// ever sees scroll-wheel events (`PageSwipeMonitor`), and the stage is not a
/// page, so it is off there anyway; the lyric column's click and scroll handling
/// live in the lines' own rect, 76 pt above the bar. The grab area the caller
/// lays this out in is the part that is taller than the bar.
struct PlaybackScrubber: View {
    @ObservedObject var media: MediaController
    /// The bar's width; the grab area is as wide.
    var width: CGFloat
    /// The drawn bar's height. The view is laid out in a taller frame and
    /// centres the bar in it, so what is grabbed is more than what is drawn.
    var trackHeight: CGFloat
    var radius: CGFloat
    var track: Color
    var fill: Color
    /// The panel's presented song (`NowPlayingPresenter`): during a hold the
    /// bar stays where the leaving song was, at that song's length. Nil draws
    /// the controller live.
    var nowPlaying: NowPlayingPresenter.Frame? = nil
    /// The fraction under the pointer or finger once it has rested a moment or
    /// is dragging, nil otherwise. The player's elapsed and remaining labels
    /// read the time at it instead of the clock's.
    var onPreviewChange: (Double?) -> Void = { _ in }

    @State private var hover = false
    /// Set once the pointer has rested on the bar for a moment.
    ///
    /// The elapsed label reads the time under the pointer while it is on the
    /// bar. Filmed on 2026-09-21: a pointer only crossing the bar on its way to
    /// the skip button flashed 1:42, 1:55, 2:14 over the time playing, and it
    /// read as the clock jumping about. A crossing is too quick to arm it.
    @State private var previewArmed = false
    @State private var previewArmTask: Task<Void, Never>?
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?
    /// Cursor x inside the bar while hovering.
    @State private var hoverX: CGFloat?

    /// Where the bar is drawn: the finger while dragging, otherwise the clock.
    static func fraction(scrubbing: Double?, position: TimeInterval, duration: TimeInterval) -> Double {
        if let scrubbing { return scrubbing }
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var progress: Double {
        Self.fraction(
            scrubbing: scrubbing, position: media.shownPosition(nowPlaying), duration: media.shownDuration(nowPlaying)
        )
    }

    private var previewFraction: Double? {
        if let scrubbing { return scrubbing }
        guard hover, previewArmed, let hoverX else { return nil }
        return ScrubPreview.fraction(x: hoverX, width: width, duration: media.duration)
    }

    var body: some View {
        let width = width
        let filled = width * progress
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(track)
                .frame(height: trackHeight)
            // Deliberately unanimated: a seek has to land under the cursor at
            // once. Smoothness comes from the tick rate instead.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .frame(width: max(filled, trackHeight), height: trackHeight)
                .opacity(filled > 0 ? 1 : 0)
            if hover {
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(filled - 5.5, 0), width - 11))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        // 23 pt to grab and 7 to draw (F-014): the strip sits near the top of
        // the screen, and a 7 pt target had to be aimed at.
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
            previewArmTask?.cancel()
            guard inside else {
                previewArmed = false
                return
            }
            previewArmTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ScrubPreview.dwell))
                guard !Task.isCancelled else { return }
                previewArmed = true
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0, media.duration > 0 else { return }
                    scrubbing = min(max(value.location.x / width, 0), 1)
                }
                .onEnded { value in
                    guard width > 0, media.duration > 0 else { return }
                    let target = min(max(value.location.x / width, 0), 1)
                    // Seek first: clearing `scrubbing` beforehand would drop the
                    // bar back to the old position for a frame.
                    media.seek(to: media.duration * target)
                    scrubbing = nil
                }
        )
        .animation(Theme.contentAnimation, value: hover)
        .onChange(of: previewFraction) { _, fraction in onPreviewChange(fraction) }
        .onDisappear {
            previewArmTask?.cancel()
            onPreviewChange(nil)
        }
        // A capsule with a drag gesture is nothing to assistive tech; see
        // `playbackPositionAccessibility` for why it is a slider.
        .playbackPositionAccessibility(
            shown: progress * media.duration,
            duration: media.duration,
            position: { media.position },
            seek: { media.seek(to: $0) }
        )
    }
}

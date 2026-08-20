import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scrubHover = false
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?
    /// Cursor x inside the bar while hovering, for the floating time preview.
    @State private var hoverX: CGFloat?
    /// Set once the current track has waited long enough for artwork that it
    /// is evidently not coming. Some sources never publish a cover, and a
    /// shimmer that promises one forever reads as stuck, not loading.
    @State private var artworkWaitExpired = false

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 122

    var body: some View {
        if let track = media.track {
            HStack(spacing: 18) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 3)

                    Spacer(minLength: 6)
                    controls
                    Spacer(minLength: 6)
                    // A live stream has no duration, and a scrubber with no
                    // length is a control that reads 0:00 / 0:00, refuses to
                    // be dragged, and looks broken rather than absent.
                    if media.duration > 0 {
                        scrubber
                    }
                    lyricsLine
                }
                .frame(height: blockHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: track.key) {
                guard NotchViewModel.showLyricsEnabled else {
                    lyrics.clear()
                    return
                }
                lyrics.load(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: media.duration
                )
            }
            // Title and artist arrive together, so the whole column can cross-
            // fade as one unit when the track changes.
            .animation(Theme.artworkAnimation, value: track.key)
        } else {
            emptyState
        }
    }

    /// The system often repeats the title as the album name; showing
    /// "Artist — Title" twice reads like a bug.
    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Artwork

    private func artwork(for track: MediaController.Track) -> some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if artworkWaitExpired {
                // Quiet placeholder, not a shimmer: the wait is over and the
                // cover is not coming for this track.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.tertiary)
                    )
                    .transition(.opacity)
            } else {
                SkeletonBox(cornerRadius: 14)
            }
        }
        .task(id: track.key) {
            artworkWaitExpired = false
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            artworkWaitExpired = true
        }
        .frame(width: 118, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // The same shape again, this time for the pointer. `clipShape` hides
        // the overflow but does not stop it being touched, and `.fill` on a
        // cover that is not square overflows a long way: a 16:9 thumbnail —
        // what a video in a browser tab publishes — comes out 211 pt wide in
        // this 118 pt box, so 46 pt of invisible picture hangs over each side.
        // The left side is the tab rail, and the four icons behind that
        // overhang stopped answering the pointer (#22).
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .animation(Theme.artworkAnimation, value: media.artwork)
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(formatTime(progress * media.duration))
                .frame(width: 32, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    // Deliberately unanimated: a seek has to land under the
                    // cursor at once. Smoothness comes from the tick rate
                    // instead, which keeps each step well under a pixel.
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .offset(x: min(max(filled - 5.5, 0), width - 11))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { scrubHover = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            // Seek first: clearing `scrubbing` beforehand would
                            // drop the bar back to the old position for a frame
                            // before the new one lands.
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.contentAnimation, value: scrubHover)
                .overlay(alignment: .topLeading) {
                    previewBubble(width: width, filled: filled)
                }
            }
            .frame(height: 14)
            // A capsule with a drag gesture is nothing at all to assistive
            // tech. Declared as one adjustable element instead, seeking in
            // five-percent steps, so the position can be both heard and moved
            // without the pointer.
            .accessibilityElement()
            .accessibilityLabel(localized("Playback Position"))
            .accessibilityValue(
                localized(
                    "%@ of %@",
                    formatTime(progress * media.duration),
                    formatTime(media.duration)
                )
            )
            .accessibilityAdjustableAction { direction in
                let step = media.duration * 0.05
                switch direction {
                case .increment: media.seek(to: media.position + step)
                case .decrement: media.seek(to: media.position - step)
                @unknown default: break
                }
            }

            Text(formatTime(media.duration))
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    /// Bubble width is fixed rather than measured: formatTime yields "m:ss"
    /// through "mm:ss" in the 10 pt monospaced ramp, which all fit in 44 pt,
    /// and a constant keeps ScrubPreview's clamping deterministic.
    private static let bubbleWidth: CGFloat = 44

    /// Floating time preview above the bar. Drag wins over hover: while a
    /// drag is in flight the bubble follows the thumb, not the cursor.
    @ViewBuilder
    private func previewBubble(width: CGFloat, filled: CGFloat) -> some View {
        let anchorX: CGFloat? = scrubbing != nil ? filled : hoverX
        if let anchorX,
           scrubbing != nil || scrubHover,
           let fraction = ScrubPreview.fraction(x: anchorX, width: width, duration: media.duration) {
            Text(formatTime(fraction * media.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: Self.bubbleWidth, height: 18)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .position(
                    x: ScrubPreview.bubbleCenterX(x: anchorX, width: width, bubbleWidth: Self.bubbleWidth),
                    y: -17
                )
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(Theme.contentAnimation, value: scrubHover)
        }
    }

    // MARK: - Transport

    /// Skipping is dimmed, not hidden, when the player does not offer it — a
    /// video in a browser tab has nothing to skip to, so the command would
    /// leave and nothing would happen. Dim says "not here"; a button that
    /// looks live and does nothing says "broken". The system's own Now Playing
    /// widget dims the same two arrows on the same session.
    private var controls: some View {
        HStack(spacing: 20) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                .accessibilityLabel(localized("Previous Track"))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 40, prominent: true))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                .accessibilityLabel(localized("Next Track"))
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: media.canSkip)
    }

    /// How far ahead of the clock the lyric runs.
    ///
    /// Three real delays stack between the singer and the screen: the position
    /// ticks four times a second, so a line lands up to 250ms after its
    /// timestamp; the crossfade spends another 160ms arriving; and the
    /// pipeline's own readings run slightly behind the audio. Leading by
    /// roughly their sum is what karaoke has always done — the line appears as
    /// the voice does, not noticeably after it.
    private static let lyricsLead: TimeInterval = 0.45

    /// One line, sung now, where the eye already is — with the sung part of it
    /// brightening as the voice moves through. No scrolling wall of text: the
    /// pane is 122pt of album art and transport, and the lyric is a caption to
    /// the music, not a document.
    @ViewBuilder
    private var lyricsLine: some View {
        if case .synced(let lines) = lyrics.state {
            let at = media.position + Self.lyricsLead
            let current = LyricsStore.current(in: lines, at: at)
            if let line = current.line {
                // Where the voice stands inside this line, 0...1. The catalogue
                // carries line timestamps, not word ones, so within a line the
                // sweep is linear time — even pacing, which is what singing
                // mostly is. The end of the last line borrows a spoken-line
                // length rather than running to the end of the track.
                let end = current.next?.at ?? line.at + 6
                let span = max(end - line.at, 0.5)
                let fraction = min(max((at - line.at) / span, 0), 1)
                KaraokeLine(text: line.text, fraction: fraction, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
                    // Keyed so a line change crossfades instead of morphing
                    // glyph-by-glyph in place.
                    .id(line.at)
                    .transition(.opacity)
                    .animation(Theme.contentAnimation, value: line.at)
                    .accessibilityLabel(localized("Lyrics"))
                    .accessibilityValue(line.text)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text("Nothing is playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A line of lyric whose sung part is bright and whose unsung part is dim,
/// the boundary sweeping with the voice.
///
/// A mask over a second copy of the same text, not per-word styling: the
/// brief asked for rhythm, not typography — no underline, no boxes, just the
/// reading edge moving. The linear animation between position ticks is what
/// turns four updates a second into one continuous sweep.
private struct KaraokeLine: View {
    let text: String
    let fraction: Double
    let reduceMotion: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .mask(
                            GeometryReader { geo in
                                Rectangle()
                                    .frame(width: geo.size.width * fraction)
                                    .animation(.linear(duration: 0.25), value: fraction)
                            }
                        )
                }
            }
    }
}

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
    /// True while the pane shows the full lyrics stage instead of the player.
    @State private var showingLyrics = false
    /// Hover on the caption, which surfaces its chevron.
    @State private var captionHover = false

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 122

    var body: some View {
        if let track = media.track {
            ZStack {
                if showingLyrics {
                    // The Liquid Glass entrance: blur, scale and opacity settle
                    // together, so the stage materializes rather than pops. The
                    // exit is faster than the entry, as every pane swap here is.
                    LyricsStage(media: media, lyrics: lyrics) {
                        showingLyrics = false
                    }
                    .transition(reduceMotion ? AnyTransition.opacity : .materialize)
                } else {
                    player(for: track)
                        .transition(reduceMotion ? AnyTransition.opacity : .materialize)
                }
            }
            .animation(Theme.paneAnimation, value: showingLyrics)
            // Leaving the track folds the stage: the next song starts on the
            // player, and a stage left open for a track without lyrics would
            // open onto its own empty state.
            .onChange(of: track.key) { _, _ in showingLyrics = false }
            .onAppear {
                media.refreshPlaybackModes()
                if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                    DebugTrail.note("MediaPane track=\(track.title) showingLyrics=\(showingLyrics)")
                }
            }
            // Verification hook, environment-gated: launching the binary with
            // DI_OPEN_LYRICS=1 opens the stage without a pointer, which is how
            // an agent without Accessibility permission can screenshot it. An
            // app launched normally never has the variable.
            .onAppear {
                if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" { showingLyrics = true }
            }
            // The Spotify id rides in the task identity: it arrives a beat
            // after the metadata, and its arrival is what unlocks the
            // word-synced database, so it must re-fire the load.
            .task(id: "\(track.key)|\(media.spotifyTrackID ?? "")") {
                guard NotchViewModel.showLyricsEnabled else {
                    lyrics.clear()
                    return
                }
                lyrics.load(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: media.duration,
                    spotifyID: media.spotifyTrackID
                )
            }
        } else {
            emptyState
                .onAppear {
                    if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                        DebugTrail.note("MediaPane EMPTY (no track)")
                    }
                }
        }
    }

    private func player(for track: MediaController.Track) -> some View {
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
        // Title and artist arrive together, so the whole column can cross-
        // fade as one unit when the track changes.
        .animation(Theme.artworkAnimation, value: track.key)
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
                            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                                DebugTrail.note(String(format: "SCRUB to=%.2f", media.duration * target))
                            }
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
            // Shuffle and repeat exist only for players that can be asked —
            // hidden, not dimmed, elsewhere: unlike skipping, the concept
            // itself is absent for a browser tab, and a dim control implies a
            // state that merely is not available right now.
            if let shuffle = media.shuffleEnabled {
                Button { media.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(shuffle ? Color.white : Theme.tertiary)
                }
                .buttonStyle(NotchButtonStyle(size: 24))
                .accessibilityLabel(localized("Shuffle"))
                .accessibilityValue(shuffle ? localized("On") : localized("Off"))
            }
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
            if let mode = media.repeatMode {
                Button { media.cycleRepeat() } label: {
                    Image(systemName: mode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(mode == .off ? Theme.tertiary : Color.white)
                }
                .buttonStyle(NotchButtonStyle(size: 24))
                .accessibilityLabel(localized("Repeat"))
                .accessibilityValue(repeatValueLabel(mode))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: media.canSkip)
        .animation(Theme.contentAnimation, value: media.shuffleEnabled == nil)
        .animation(Theme.contentAnimation, value: media.repeatMode == nil)
    }

    private func repeatValueLabel(_ mode: PlayerBridge.RepeatMode) -> String {
        switch mode {
        case .off: return localized("Off")
        case .all: return localized("All Tracks")
        case .one: return localized("This Track")
        }
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
    /// With the position corrected against the player's own clock the
    /// pipeline's share of the lag is gone; what remains is display cost.
    private static let precisionLyricsLead: TimeInterval = 0.25

    /// One line, sung now, where the eye already is — with the sung part of it
    /// brightening as the voice moves through. No scrolling wall of text: the
    /// pane is 122pt of album art and transport, and the lyric is a caption to
    /// the music, not a document.
    @ViewBuilder
    private var lyricsLine: some View {
        if media.positionSettled, case .synced(let lines) = lyrics.state {
            let at = media.position + (media.precisionSync ? Self.precisionLyricsLead : Self.lyricsLead)
            let current = LyricsStore.current(in: lines, at: at)
            if let line = current.line {
                // Where the voice stands inside this line, 0...1. The catalogue
                // carries line timestamps, not word ones, so within a line the
                // sweep is linear time — even pacing, which is what singing
                // mostly is. The end of the last line borrows a spoken-line
                // length rather than running to the end of the track.
                let end = current.next?.at ?? line.at + 6
                // The caption is the door to the stage: click it and the pane
                // becomes the full scrolling lyrics. A chevron surfaces on
                // hover so the door reads as one — a bare line of text gives
                // no hint that it goes anywhere.
                Button { showingLyrics = true } label: {
                    HStack(spacing: 5) {
                        KaraokeLine(
                            text: line.text,
                            fraction: Self.sweepFraction(line: line, at: at, end: end),
                            reduceMotion: reduceMotion
                        )
                        // Keyed so a line change crossfades instead of morphing
                        // glyph-by-glyph in place.
                        .id(line.at)
                        .transition(.opacity)
                        if captionHover {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { captionHover = $0 }
                .padding(.top, 5)
                .animation(Theme.contentAnimation, value: line.at)
                .animation(Theme.contentAnimation, value: captionHover)
                .accessibilityLabel(localized("Lyrics"))
                .accessibilityValue(line.text)
                .accessibilityHint(localized("Opens the full lyrics"))
            }
        }
    }

    /// Real word timing when a source had it; the singing-speed estimate only
    /// for lines that never got any.
    private static func sweepFraction(line: LyricsStore.Line, at: TimeInterval, end: TimeInterval) -> Double {
        guard line.words.isEmpty else {
            return WordSyncedLyrics.wordFraction(words: line.words, at: at, lineEnd: end)
        }
        let span = LyricsStore.sweepSpan(text: line.text, slot: end - line.at)
        return min(max((at - line.at) / span, 0), 1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text(localized("Nothing is playing"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            // And an affordance, because a dead end teaches people not to
            // open the tab. One button per player that is actually installed.
            HStack(spacing: 8) {
                ForEach(PlayerApp.allCases.filter(Self.isInstalled), id: \.rawValue) { app in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Self.applicationPath(for: app) ?? ""))
                    } label: {
                        Text(localized("Open %@", app.displayName))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func isInstalled(_ app: PlayerApp) -> Bool {
        applicationPath(for: app) != nil
    }

    private static func applicationPath(for app: PlayerApp) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path
    }
}

/// A line of lyric whose sung part is bright and whose unsung part is dim,
/// the boundary sweeping with the voice.
///
/// A mask over a second copy of the same text, not per-word styling: the
/// brief asked for rhythm, not typography — no underline, no boxes, just the
/// reading edge moving. The linear animation between position ticks is what
/// turns four updates a second into one continuous sweep.
struct KaraokeLine: View {
    let text: String
    let fraction: Double
    let reduceMotion: Bool
    var accent: Color = Color.white.opacity(0.92)
    /// The caption's size by default; the stage passes its own. A parameter
    /// rather than a `.font()` from outside, because the internal `Text`s set
    /// an explicit font and would silently ignore one.
    var font: Font = .system(size: 11, weight: .medium)
    var base: Color = Theme.tertiary
    /// One line for the caption; the stage lets long lines wrap.
    var lineLimit: Int = 1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(base)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    Text(text)
                        .font(font)
                        .foregroundStyle(accent)
                        .lineLimit(lineLimit)
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

import CoreAudio
import SwiftUI

/// The media player shown while the Mac is locked.
///
/// Modelled on what the paid field ships on its lock screens — Alcove's
/// frosted card under the clock is the reference grammar: artwork with its
/// own shadow, title over dimmed artist, a thin seek bar flanked by elapsed
/// and remaining, a real transport row — then pushed past it with the two
/// things this app has that they do not: the word-synced karaoke line, and
/// chrome tinted from the artwork itself so no two tracks light the card the
/// same way.
///
/// Interactive, deliberately: previous, play/pause, next and the seek bar all
/// answer clicks, and the panel's hit region is cut to exactly this card, so
/// the rest of the lock screen still belongs to the password field.
struct LockScreenCard: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject private var spotify = SpotifyAccount.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var palette: ArtworkPalette?
    @State private var scrubbing: Double?
    /// The output picker, open over the card's own surface. A system menu
    /// would have to draw outside the card, and outside the card is the
    /// password field's — the panel takes no clicks there by design.
    @State private var showingOutputs = false
    @State private var outputs: [AudioOutputs.Output] = []
    @State private var currentOutput: AudioDeviceID?
    /// Read through `@AppStorage` so changing it in Settings redraws the card
    /// while it is on screen, rather than at the next lock.
    @AppStorage(NotchViewModel.lockCardStyleKey) private var styleRaw = NotchViewModel.LockCardStyle.glass.rawValue

    private var style: NotchViewModel.LockCardStyle {
        NotchViewModel.LockCardStyle(rawValue: styleRaw) ?? .glass
    }

    static let size = CGSize(width: 500, height: 222)

    private var accent: Color {
        guard let palette, palette.isVivid else { return .white }
        return Color(nsColor: palette.dominant)
    }

    var body: some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                        lyricLine
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 10)
                    LockWaveform(accent: accent, animating: media.isPlaying && !reduceMotion)
                }

                Spacer(minLength: 12)
                seekBar
                controls
                    .padding(.top, 14)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            // Every mark on the card carries its own shadow on glass. That is
            // how white type survives a bright wallpaper without a scrim
            // painting the wallpaper out — the system does the same on its own
            // lock screen, and it is why the clock there is readable over
            // anything.
            .shadow(color: .black.opacity(style == .glass ? 0.55 : 0), radius: 4, y: 1)
            .frame(width: Self.size.width, height: Self.size.height)
            .glassSurface(
                cornerRadius: 30,
                elevation: .card,
                // The cover's colour, carried weakly, and its light behind the
                // pane — but only on glass. Solid is meant to be a panel.
                tint: style == .glass ? (palette?.isVivid == true ? Color(nsColor: palette!.dominant) : nil) : nil,
                light: style == .glass ? media.artwork : nil,
                samplesBackdrop: style == .glass
            )
            .background {
                // Solid keeps its own opaque ground beneath the glass recipe,
                // for the bright, busy wallpapers glass cannot win against.
                if style == .solid {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(.black.opacity(0.45))
                        }
                }
            }
            // Two shadows: a tight contact shadow that seats the card on the
            // wallpaper, and a wide soft one for depth. One shadow doing both
            // jobs always looks like neither.
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.38), radius: 30, y: 14)
            .environment(\.colorScheme, .dark)
            .task(id: media.artwork) {
                // Off the main actor. Extraction downsamples the cover through
                // CoreImage, and doing that inline on every track change spent
                // tens of milliseconds of main-thread time in the same frame
                // the card was animating — the very cost this codebase already
                // moved artwork decoding off the main thread to avoid.
                guard let artwork = media.artwork else {
                    palette = nil
                    return
                }
                palette = await Task.detached(priority: .userInitiated) {
                    ArtworkPalette.extract(from: artwork)
                }.value
            }
            .task(id: "\(track.key)|\(media.spotifyTrackID ?? "")") {
                guard NotchViewModel.showLyricsEnabled else { return }
                lyrics.load(
                    title: track.title, artist: track.artist,
                    album: track.album, duration: media.duration,
                    spotifyID: media.spotifyTrackID
                )
            }
            .transition(.opacity)
        }
    }

    // MARK: - Pieces

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        )
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 5)

            // The heart rides the cover's top corner now that the transport
            // row belongs to the five glyphs the reference card carries. It
            // belongs to the track either way, and the track is what the cover
            // is.
            .overlay(alignment: .topTrailing) {
                heart.padding(4)
            }

            // The source badge the field overlaps on the artwork corner —
            // instant context, no text.
            if let source = media.sourceName, !source.isEmpty {
                Text(String(source.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .offset(x: 5, y: 5)
            }
        }
    }

    @ViewBuilder
    private var lyricLine: some View {
        if media.positionSettled, case .synced(let lines) = lyrics.state {
            // The same clock as the caption and the stage. This used to be a
            // hardcoded `+ 0.25`, which consulted neither the precision flag nor
            // the listener's own correction — so the card sat on a third clock,
            // and Sync moved everything except it.
            let at = LyricSweep.position(
                media.position,
                precisionSync: media.precisionSync,
                userOffset: lyrics.userOffset
            )
            if let shown = LyricSweep.displayed(lines: lines, at: at) {
                let line = shown.line
                let end = shown.end
                KaraokeText(
                    text: line.text,
                    // Credits are shown, never swept — see the caption.
                    fraction: line.isCredit || !shown.swept
                        ? 0
                        : LyricSweep.fraction(line: line, at: at, end: end),
                    reduceMotion: reduceMotion,
                    accent: accent
                )
                .italic(line.isCredit)
                .id(line.at)
                .transition(.opacity)
                .animation(Theme.contentAnimation, value: line.at)
            }
        }
    }

    private var fraction: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var seekBar: some View {
        HStack(spacing: 12) {
            Text(formatTime(fraction * media.duration))
                .frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                    Capsule()
                        .fill(accent.opacity(0.95))
                        .frame(width: width * fraction, height: 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0, media.duration > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0, media.duration > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 16)
            // The track's length, not what is left of it. A card this size is
            // read at a glance from across a room, and "7:03" answers *how long
            // is this* — the question a countdown cannot.
            Text(formatTime(media.duration))
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }

    /// Five glyphs spread from edge to edge, drawn bare.
    ///
    /// No circular wells behind them: on a surface this glossy a filled disc
    /// reads as a button glued onto the glass, where the reference cards float
    /// the symbols directly on it. Shuffle anchors the left, the output device
    /// the right, and the transport takes the middle.
    private var controls: some View {
        HStack(spacing: 0) {
            shuffle
            Spacer(minLength: 0)
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 22, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .accessibilityLabel(localized("Previous Track"))
            Spacer(minLength: 0)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Spacer(minLength: 0)
            Button { media.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 22, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .accessibilityLabel(localized("Next Track"))
            Spacer(minLength: 0)
            output
        }
        .frame(height: 34)
    }

    /// Shuffle, where the player has it to give. Dimmed rather than missing
    /// when the source has no such idea — a browser tab does not shuffle — so
    /// the row keeps its shape whatever is playing.
    private var shuffle: some View {
        ModeToggle(
            symbol: "shuffle",
            isOn: media.shuffleEnabled == true,
            accent: accent,
            size: 34,
            glyphSize: 17
        ) { media.toggleShuffle() }
        .disabled(media.shuffleEnabled == nil)
        .opacity(media.shuffleEnabled == nil ? 0.3 : 1)
        .accessibilityLabel(localized("Shuffle"))
        .accessibilityValue(media.shuffleEnabled == true ? localized("On") : localized("Off"))
    }

    /// Where the sound comes out, and how to send it somewhere else.
    ///
    /// No app's audio can be moved individually from outside it, but every app
    /// follows the system's default output — so "play it on the speakers
    /// instead" is a real thing this button can do, and the glyph says which
    /// kind of thing is playing now.
    private var output: some View {
        Button {
            outputs = AudioOutputs.available()
            currentOutput = AudioOutputs.current()
            showingOutputs.toggle()
        } label: {
            Image(systemName: outputSymbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportGlyphStyle(size: 34))
        .help(localized("Sound Output"))
        .accessibilityLabel(localized("Sound Output"))
    }

    private var outputSymbol: String {
        guard let currentOutput,
              let device = outputs.first(where: { $0.id == currentOutput }) else {
            return "laptopcomputer"
        }
        return AudioOutputs.symbol(forTransport: device.transport)
    }

    /// The picker itself: the devices this Mac can play through, the current
    /// one ticked. Sized to the card, because it lives inside it.
    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(outputs) { device in
                Button {
                    AudioOutputs.select(device.id)
                    currentOutput = device.id
                    showingOutputs = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AudioOutputs.symbol(forTransport: device.transport))
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text(device.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if device.id == currentOutput {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240, alignment: .leading)
        .glassSurface(cornerRadius: 14, elevation: .popover, samplesBackdrop: false)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Sound Output"))
    }

    /// Saved-to-Liked-Songs, through the user's own authorized account —
    /// the one Spotify feature with no local API at all. Hidden rather than
    /// disabled when it cannot work: a heart that never answers is worse
    /// than no heart.
    @ViewBuilder
    private var heart: some View {
        if spotify.isConnected, !spotify.apiBlocked, !spotify.tokenUnavailable,
           let id = media.spotifyTrackID {
            // Filled means the song is in Liked Songs, hollow means it is not —
            // and until the library has actually answered, hollow-but-dimmed
            // means "asking". Drawing a plain hollow heart while the answer was
            // still in flight stated, every time, that a liked song was not
            // liked.
            let known = spotify.saved[id]
            let isSaved = known ?? false
            Button { spotify.toggleSaved(trackID: id) } label: {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSaved ? accent : .white)
                    .opacity(known == nil ? 0.45 : 1)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .disabled(known == nil)
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? localized("Remove from Liked Songs") : localized("Add to Liked Songs"))
            .task(id: id) { spotify.refreshSavedState(trackID: id) }
        } else {
            EmptyView()
        }
    }
}
/// Five bars breathing with the music, tinted from the artwork — the
/// heartbeat every reference player carries at its edge.
private struct LockWaveform: View {
    let accent: Color
    let animating: Bool

    var body: some View {
        if animating {
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: 0)
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                let phase = time == 0 ? 0.35
                    : 0.5 + 0.5 * sin(time * (3.1 + Double(index) * 0.7) + Double(index) * 1.7)
                Capsule()
                    .fill(accent.opacity(0.85))
                    .frame(width: 3, height: 6 + 14 * phase)
            }
        }
        .frame(height: 22, alignment: .center)
    }
}

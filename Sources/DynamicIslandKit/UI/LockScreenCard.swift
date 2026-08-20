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

    static let size = CGSize(width: 480, height: 190)

    private var accent: Color {
        guard let palette, palette.isVivid else { return .white }
        return Color(nsColor: palette.dominant)
    }

    var body: some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        lyricLine
                    }
                    Spacer(minLength: 8)
                    LockWaveform(accent: accent, animating: media.isPlaying && !reduceMotion)
                }

                Spacer(minLength: 10)
                seekBar
                controls
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(width: Self.size.width, height: Self.size.height)
            .background {
                ZStack {
                    // The glass Alcove uses, with our ambience on top: the
                    // artwork's own color breathing faintly through the frost.
                    Rectangle().fill(.ultraThinMaterial)
                    if let palette, palette.isVivid {
                        Color(nsColor: palette.dominant).opacity(0.10)
                    }
                    LinearGradient(
                        colors: [.black.opacity(0.15), .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .environment(\.colorScheme, .dark)
            .task(id: media.artwork) {
                palette = media.artwork.flatMap(ArtworkPalette.extract(from:))
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
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)

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
            let at = media.position + 0.25
            let current = LyricsStore.current(in: lines, at: at)
            if let line = current.line {
                let end = current.next?.at ?? line.at + 6
                KaraokeLine(
                    text: line.text,
                    fraction: Self.sweepFraction(line: line, at: at, end: end),
                    reduceMotion: reduceMotion,
                    accent: accent
                )
                .id(line.at)
                .transition(.opacity)
                .animation(Theme.contentAnimation, value: line.at)
            }
        }
    }

    static func sweepFraction(line: LyricsStore.Line, at: TimeInterval, end: TimeInterval) -> Double {
        guard line.words.isEmpty else {
            return WordSyncedLyrics.wordFraction(words: line.words, at: at, lineEnd: end)
        }
        let span = LyricsStore.sweepSpan(text: line.text, slot: end - line.at)
        return min(max((at - line.at) / span, 0), 1)
    }

    private var fraction: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var seekBar: some View {
        HStack(spacing: 10) {
            Text(formatTime(fraction * media.duration))
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Capsule()
                        .fill(accent.opacity(0.9))
                        .frame(width: width * fraction, height: 4)
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
            .frame(height: 14)
            // Remaining, not total — the lock-screen convention every
            // reference card follows.
            Text("-" + formatTime(max(media.duration - fraction * media.duration, 0)))
                .frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }

    private var controls: some View {
        HStack(spacing: 26) {
            heart
            Spacer()
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: 32))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                .accessibilityLabel(localized("Previous Track"))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 42, prominent: true))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: 32))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                .accessibilityLabel(localized("Next Track"))
            Spacer()
            // Symmetry for the heart, so the transport cluster stays centered.
            Color.clear.frame(width: 32, height: 32)
        }
    }

    /// Saved-to-Liked-Songs, through the user's own authorized account —
    /// the one Spotify feature with no local API at all. Hidden rather than
    /// disabled when it cannot work: a heart that never answers is worse
    /// than no heart.
    @ViewBuilder
    private var heart: some View {
        if spotify.isConnected, !spotify.apiBlocked, let id = media.spotifyTrackID {
            let isSaved = spotify.saved[id] ?? false
            Button { spotify.toggleSaved(trackID: id) } label: {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .foregroundStyle(isSaved ? accent : .white)
            }
            .buttonStyle(NotchButtonStyle(size: 32))
            .accessibilityLabel(isSaved ? localized("Remove from Liked Songs") : localized("Add to Liked Songs"))
            .task(id: id) { spotify.refreshSavedState(trackID: id) }
        } else {
            Color.clear.frame(width: 32, height: 32)
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

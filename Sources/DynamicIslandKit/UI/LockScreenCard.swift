import SwiftUI

/// The media card shown while the Mac is locked.
///
/// Bigger than the pill because the lock screen has room the notch does not:
/// full artwork, title, artist and source, a live progress bar, and the line
/// being sung. Display only — the lock screen takes media keys (pause from
/// the keyboard works with the shield up) but its pointer belongs to the
/// password field, and a clickable card would fight it for every event.
///
/// Styled from system materials and semantic styles rather than painted
/// colors: `.regularMaterial`, vibrancy hierarchy, continuous corners. That
/// is what makes it read as part of the OS on this macOS — and the same
/// choice is the only honest form of future-proofing, because the system
/// restyles its own materials on every release while a hand-painted imitation
/// of today's look would rot.
struct LockScreenCard: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore

    var body: some View {
        if let track = media.track {
            HStack(spacing: 16) {
                artwork
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)

                    Spacer(minLength: 8)
                    lyricLine
                    Spacer(minLength: 8)
                    progress
                }
            }
            .padding(18)
            .frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
            .environment(\.colorScheme, .dark)
            .task(id: "\(track.key)|\(media.spotifyTrackID ?? "")") {
                guard NotchViewModel.showLyricsEnabled else { return }
                lyrics.load(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: media.duration,
                    spotifyID: media.spotifyTrackID
                )
            }
            .transition(.opacity)
        }
    }

    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if let source = media.sourceName, !source.isEmpty { parts.append(source) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var lyricLine: some View {
        if media.positionSettled, case .synced(let lines) = lyrics.state {
            let at = media.position + 0.25
            let current = LyricsStore.current(in: lines, at: at)
            if let line = current.line {
                Text(line.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(line.at)
                    .transition(.opacity)
                    .animation(Theme.contentAnimation, value: line.at)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.secondary)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            HStack {
                Text(formatTime(media.position))
                if !media.isPlaying {
                    Spacer()
                    Text(localized("Paused"))
                }
                Spacer()
                Text(formatTime(media.duration))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private var fraction: Double {
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }
}

import AppKit
import SwiftUI

/// A new track on the shut island (spec §3.5, amended 2026-11-15; owner: "exactly
/// how the volume changer is shown, just under the physical notch"): the volume
/// pop-up with the song in it — the title where the output's name is, the cover
/// where the symbol is, the artist along the bar, the equalizer where the number
/// is (`NewTrackAlertLayout`). Laid out as `HUDPillContent` is, by offsets and
/// baselines in one `.topLeading` stack, so the two cannot come to sit
/// differently on any notch.
///
/// It replaced the peek's widening of the song's own pill to 520 × 50. That
/// pill stays mounted and faded underneath, as it does under the pop-up, so the
/// cover's travel into the panel is untouched when the alert folds.
struct NewTrackAlertContent: View {
    let song: NowPlayingPresenter.Presented
    let size: CGSize
    let notchHeight: CGFloat
    /// The compact island's equalizer state: moving and tinted while playing,
    /// at rest in tertiary while paused.
    let animatesEqualizer: Bool
    let equalizerColors: CompactEqualizerMotion.BarColors
    let reduceMotion: Bool

    var body: some View {
        let cover = NewTrackAlertLayout.coverFrame(notchHeight: notchHeight)
        let bars = NewTrackAlertLayout.equalizerFrame(islandWidth: size.width, notchHeight: notchHeight)
        ZStack(alignment: .topLeading) {
            Text(song.track.title)
                .islandFont(NewTrackAlertLayout.titleSize)
                .foregroundStyle(Color.white.opacity(NewTrackAlertLayout.titleOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: NewTrackAlertLayout.titleWidth(islandWidth: size.width), alignment: .leading)
                .islandBaseline(NewTrackAlertLayout.titleBaseline(notchHeight: notchHeight))
                .offset(x: NewTrackAlertLayout.titleLeading)
            coverView
                .frame(width: cover.width, height: cover.height)
                .clipShape(RoundedRectangle(cornerRadius: NewTrackAlertLayout.coverRadius, style: .continuous))
                .overlay(
                    // The compact cover's hairline, so a black cover keeps its
                    // edge on the black island.
                    RoundedRectangle(cornerRadius: NewTrackAlertLayout.coverRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .offset(x: cover.minX, y: cover.minY)
            Text(song.track.artist)
                .islandFont(NewTrackAlertLayout.artistSize)
                .foregroundStyle(Color.white.opacity(NewTrackAlertLayout.artistOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: NewTrackAlertLayout.artistWidth(islandWidth: size.width), alignment: .leading)
                .islandBaseline(NewTrackAlertLayout.artistBaseline(notchHeight: notchHeight))
                .offset(x: NewTrackAlertLayout.artistLeading)
            CompactEqualizer(isAnimating: animatesEqualizer, colors: equalizerColors)
                .frame(width: bars.width, height: bars.height)
                .offset(x: bars.minX, y: bars.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // No element of its own: like the pop-up, it is the island's value
        // (`closedIslandValue`), and VoiceOver hears the track as it arrives
        // (`NotchController.sneakPeek`).
    }

    /// The song's cover, or the well and its note the compact pill draws when
    /// there is none (§3.2) — never a hole. A skip inside the hold swaps it on
    /// the cover's own curve, keyed on the presented song.
    @ViewBuilder private var coverView: some View {
        if let artwork = song.artwork {
            Color.clear
                .overlay {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .trackSwapCover(song.track.key, reduceMotion: reduceMotion)
                }
        } else {
            Theme.coverWell
                .overlay {
                    GlyphImage(.music, pointSize: Theme.TypeRole.caption.size)
                        .foregroundStyle(Theme.secondary)
                }
        }
    }
}

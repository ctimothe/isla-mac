import SwiftUI

/// One line of a lyric, drawn the one way.
///
/// The island's stage and the lock card both show the same song, and they used
/// to each decide for themselves what a sung line looks like, what a passed one
/// fades to, and what a credit does. They drifted, which is how the two came to
/// disagree about the line before the first timestamp. Anything added to the
/// highlighter from here — a different falloff, a per-word emphasis, a
/// different treatment for a credit — lands on every surface at once, because
/// there is only this one.
///
/// The container is still each surface's own: the stage scrolls a whole song
/// and the card holds a fixed window of it. What a *line* is, is here.
struct LyricRow: View {
    let line: LyricsStore.Line
    /// Whether the voice is inside this line right now.
    let isCurrent: Bool
    /// How many lines away from the current one, for the depth falloff.
    let distance: Int
    /// The moment to sweep against, lead already applied.
    let at: TimeInterval
    /// When this line gives way to the next.
    let end: TimeInterval

    var font: Font = .system(size: 16, weight: .bold)
    var lineLimit: Int = 1
    var accent: Color = .white
    var reduceMotion: Bool = false
    /// Choosing a line is choosing the song's place in it.
    var seek: (() -> Void)?

    var body: some View {
        Button { seek?() } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(seek == nil)
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if line.isCredit {
            // Never swept, never bold. A credit is on screen because the song
            // has not started, and dressing it as the current lyric would claim
            // somebody is singing "Produced by".
            Text(line.text)
                .font(font)
                .italic()
                .foregroundStyle(.white.opacity(isCurrent ? 0.68 : 0.34))
                .lineLimit(lineLimit)
        } else if isCurrent {
            KaraokeText(
                text: line.text,
                fraction: LyricSweep.fraction(line: line, at: at, end: end),
                reduceMotion: reduceMotion,
                accent: accent,
                font: font,
                // Brighter than any neighbour even before the sweep arrives:
                // the line being sung must never be the darkest thing on screen.
                base: .white.opacity(0.5),
                lineLimit: lineLimit
            )
        } else {
            // Depth through opacity alone. An early cut blurred and fractionally
            // scaled these, which at reading size is not depth — it is smeared
            // type, because subpixel scaling rasterises every glyph soft.
            Text(line.text)
                .font(font)
                .foregroundStyle(.white.opacity(distance == 1 ? 0.34 : 0.18))
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }
}

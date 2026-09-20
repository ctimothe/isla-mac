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

    /// A size rather than a `Font`, so the row can apply the tracking that size
    /// wants — SF ships a table for it and `.system(size:)` leaves it behind.
    /// The default is the title role both surfaces had already gathered at.
    var fontSize: CGFloat = Theme.TypeRole.title.size
    var weight: Font.Weight = .bold
    var lineLimit: Int = 1
    var accent: Color = .white
    var reduceMotion: Bool = false
    /// A line timeline, or an unmeasured player clock, highlights the whole
    /// current line. It must never animate a made-up word progression.
    var wordTimingEnabled = false
    /// Choosing a line is choosing the song's place in it.
    var seek: (() -> Void)?

    /// The dimmest a context line may go.
    ///
    /// The falloff below sits at white 0.18, which is 1.54:1 over black —
    /// a line nobody can read and barely a line at all. The floor lifts it to
    /// 0.28 (2.27:1) for everyone and to 0.38 (3.39:1) under Increase Contrast,
    /// past the 3.0 `ContrastRampTests` holds. Depth survives: the sung line
    /// still arrives at full white through `KaraokeText`, and the neighbour
    /// (0.34, 0.44 under Increase Contrast) still sits between floor and song.
    static func falloffFloor(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.38 : 0.28
    }

    /// The neighbour one step from the sung line.
    ///
    /// It used to sit at 0.34 at every setting, which put it *below* the far
    /// floor once Increase Contrast raised that to 0.38 — the near line dimmer
    /// than the far ones, depth inside out. 0.44 keeps it between floor and song.
    static func neighbourOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.44 : 0.34
    }

    var body: some View {
        Button { seek?() } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(seek == nil)
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    @MainActor
    @ViewBuilder
    private var content: some View {
        if line.isCredit {
            // Never swept, never bold. A credit is on screen because the song
            // has not started, and dressing it as the current lyric would claim
            // somebody is singing "Produced by".
            Text(line.text)
                .islandFont(fontSize, weight: weight)
                .italic()
                .foregroundStyle(.white.opacity(isCurrent ? 0.68 : 0.34))
                .lineLimit(lineLimit)
        } else if isCurrent {
            KaraokeText(
                text: line.text,
                fraction: wordTimingEnabled
                    ? LyricSweep.fraction(line: line, at: at, end: end)
                    : 1,
                reduceMotion: reduceMotion,
                accent: accent,
                font: .system(size: fontSize, weight: weight),
                tracking: Theme.tracking(forSize: fontSize),
                // Brighter than any neighbour even before the sweep arrives:
                // the line being sung must never be the darkest thing on screen.
                base: .white.opacity(0.5),
                lineLimit: lineLimit
            )
        } else {
            // Depth through opacity alone. An early cut blurred and fractionally
            // scaled these, which at reading size is not depth — it is smeared
            // type, because subpixel scaling rasterises every glyph soft.
            // Clamped to `falloffFloor`, never the bare 0.18: without the
            // clamp the far lines sat at 1.54:1, unreadable as text.
            Text(line.text)
                .islandFont(fontSize, weight: weight)
                .foregroundStyle(.white.opacity(falloffOpacity))
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }

    /// The context opacity for a non-sung line: the neighbour one step away,
    /// or the floor for everything further out. The floor always clears the
    /// old 0.18, so no `max` guard is needed — the clamp *is* the value.
    @MainActor
    private var falloffOpacity: Double {
        let increaseContrast = SystemAppearance.shared.increaseContrast
        guard distance != 1 else { return Self.neighbourOpacity(increaseContrast: increaseContrast) }
        return Self.falloffFloor(increaseContrast: increaseContrast)
    }
}

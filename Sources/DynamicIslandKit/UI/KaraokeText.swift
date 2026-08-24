import SwiftUI

/// The one karaoke sweep this app draws.
///
/// It replaces two renderers that each got half of it right. The caption masked a
/// duplicate `Text` with a rectangle: continuous, but geometry — on a line wrapped
/// to two rows the one rectangle lit the left half of *both* rows at once, putting
/// the reading edge in the wrong place on every long lyric. The stage split the
/// string at a character index and rebuilt an `AttributedString`: wrap-correct, but
/// text *content* cannot interpolate in SwiftUI, so the highlight could only jump —
/// and it jumped at the rate the position publishes, which is the four-times-a-
/// second ticker. One read smooth and wrong, the other read right and jerky.
///
/// A `TextRenderer` is the instrument that is both. It is handed the laid-out text,
/// so each visual row can be clipped on its own and filled in reading order; and it
/// conforms to `Animatable`, so the fraction interpolates at display rate between
/// position ticks instead of stepping with them.
struct KaraokeRenderer: TextRenderer, Animatable {
    var fraction: Double
    var accent: Color
    var base: Color

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // In reading order: the layout is its lines in order, and each line is its
        // runs in order, so flattening preserves exactly the order a person reads.
        let runs = layout.flatMap { $0 }
        // Measured in laid-out width, not in glyph count. A line of "I"s and a line
        // of "W"s take different space to print, and counting characters made the
        // edge race across one and crawl across the other.
        let total = runs.reduce(0.0) { $0 + $1.typographicBounds.width }
        guard total > 0 else { return }
        var remaining = total * min(max(fraction, 0), 1)

        for run in runs {
            let bounds = run.typographicBounds

            // The glyphs arrive white — see `KaraokeText` — so a colour multiply
            // sets a colour outright rather than darkening one already applied.
            var unsung = context
            unsung.addFilter(.colorMultiply(base))
            unsung.draw(run)

            guard remaining > 0 else { continue }
            let lit = min(remaining, bounds.width)
            remaining -= lit

            var sung = context
            // Clipped to this row alone. One rectangle spanning every row is
            // precisely the failure this renderer exists to end.
            sung.clip(
                to: Path(CGRect(
                    x: bounds.origin.x,
                    y: bounds.origin.y - bounds.ascent,
                    width: lit,
                    height: bounds.ascent + bounds.descent
                ))
            )
            sung.addFilter(.colorMultiply(accent))
            sung.draw(run)
        }
    }
}

/// A line of lyric whose sung part is bright and whose unsung part is dim, the
/// reading edge moving with the voice. Every surface that draws a lyric uses this
/// one: the caption, the stage, and the lock card.
struct KaraokeText: View {
    let text: String
    let fraction: Double
    var reduceMotion: Bool = false
    var accent: Color = Color.white.opacity(0.92)
    var font: Font = .system(size: 11, weight: .medium)
    var base: Color = Theme.tertiary
    var lineLimit: Int = 1

    var body: some View {
        Text(text)
            .font(font)
            // White on purpose, and never seen: the renderer multiplies it to the
            // colour each half of the line should be. Multiplying a colour that is
            // already dim would give a third, darker colour instead of the one
            // asked for.
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .textRenderer(
                KaraokeRenderer(
                    // Reduce Motion asks for the state, not the travel: the line
                    // still reads as the current one, it simply arrives lit rather
                    // than filling.
                    fraction: reduceMotion ? 1 : fraction,
                    accent: accent,
                    base: base
                )
            )
            // One tick of the position ticker, so the interpolation spans exactly
            // the gap between two readings and the edge never waits.
            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
    }
}

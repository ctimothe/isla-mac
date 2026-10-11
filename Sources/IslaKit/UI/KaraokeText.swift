import SwiftUI

/// The one karaoke sweep this app draws.
///
/// It replaces two renderers that each got half of it right. The caption masked a
/// duplicate `Text` with a rectangle: continuous, but geometry — on a line wrapped
/// to two rows the one rectangle lit the left half of *both* rows at once, putting
/// the reading edge in the wrong place on every long lyric. The stage split the
/// string at a character index and rebuilt an `AttributedString`: wrap-correct, but
/// text *content* cannot interpolate in SwiftUI, so the highlight could only jump —
/// and it jumped at the rate the position publishes. One read smooth and wrong,
/// the other read right and jerky.
///
/// A `TextRenderer` is the instrument that is both. It is handed the laid-out text,
/// so each visual row can be clipped on its own and filled in reading order, and
/// it draws whatever fraction it is given on the frame it is given it — which,
/// while a word-timed line is being sung, is a fraction read from the clock on
/// that very frame (see `KaraokeText.clock`).
///
/// It still conforms to `Animatable` through the fraction, because a
/// `TextRenderer` must; `KaraokeText` is what makes sure nothing animates it.
struct KaraokeRenderer: TextRenderer, Animatable {
    var fraction: Double
    var accent: Color
    var base: Color
    /// The whole line's width on one unconstrained row, when it is known.
    ///
    /// The fraction is the share of the *whole* line sung: `wordFraction`
    /// counts every word, the ones a truncation hid included. Spread over only
    /// the runs laid out, a line cut short by its line limit put the edge at
    /// half of what shows when the voice was half way through all of it — on
    /// the lock card's one row, a long Russian line sat well behind the singer
    /// (G-038). Nil draws over the laid-out width, which for a line that fits
    /// is the same thing.
    var fullWidth: CGFloat? = nil

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    /// How much of the laid-out width is lit: the fraction of the whole line,
    /// and never more than is drawn.
    ///
    /// A whole line narrower than the visible one only happens while the
    /// measurement trails a new line by a frame; taking the larger keeps a
    /// fully sung line fully lit even then.
    static func litWidth(fraction: Double, visible: CGFloat, full: CGFloat) -> CGFloat {
        let sung = CGFloat(min(max(fraction, 0), 1))
        return min(sung * max(full, visible), visible)
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
        var remaining = Self.litWidth(fraction: fraction, visible: total, full: fullWidth ?? total)

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
    /// Where the sweep stands right now, asked on every display frame; nil
    /// draws `fraction` as it is. A surface hands one in only while a
    /// word-timed line is being sung (`LyricSweep.liveFraction`).
    ///
    /// The edge used to be `fraction`, published on the 0.1 s tick and eased
    /// between ticks over a quarter of a second. Each publish re-aimed a ramp
    /// the last one had not finished, so the ramp never arrived and the edge
    /// trailed the clock by 175 ms at the median and 196 ms at p95 — the voice
    /// on time at each line change and late at every word in between (F-011,
    /// L-10). A shorter ramp only shrinks the same lag to about a tick and
    /// steps on any late publish. Placed by the clock on the frame it is
    /// drawn, the edge is at most one frame old, and nothing follows after it.
    var clock: (@MainActor () -> Double)? = nil
    var reduceMotion: Bool = false
    var accent: Color = Color.white.opacity(0.92)
    var font: Font = Theme.TypeRole.body.font()
    /// Matched to the neighbouring lines. A swept line tracked differently from
    /// the ones above and below it shifts sideways as the song moves through it,
    /// which reads as the text twitching rather than as the voice arriving.
    var tracking: CGFloat = 0
    var base: Color = Theme.tertiary
    var lineLimit: Int = 1

    /// The line's width on one unconstrained row, measured by layout and kept
    /// until the line or its type changes — not resolved again on every frame
    /// the sweep draws. See `KaraokeRenderer.fullWidth`.
    @State private var fullWidth: CGFloat?

    /// The animation the sweep's fraction changes on: none, in every case.
    ///
    /// Clock-driven, the edge is already where the clock is on each frame, and
    /// any interpolation can only put it behind. Static — line timing drawing
    /// 1, a paused song, Reduce Motion — it changes only by a cut (a seek, a
    /// pause, a setting), and a ramp across a cut is the old lag in miniature.
    /// Applied explicitly rather than left out: the renderer's fraction is
    /// animatable, and an animated transaction from outside (the stage turns
    /// its page in one) would otherwise carry the sweep along with it.
    static func sweepAnimation(reduceMotion: Bool, clockDriven: Bool) -> Animation? {
        nil
    }

    var body: some View {
        let clockDriven = clock != nil && !reduceMotion
        // One timeline always, paused unless the clock drives it, so a line
        // that starts or stops playing keeps its identity rather than being
        // swapped for another view mid-line. Paused, it costs nothing and
        // redraws only when its inputs change, as a plain view would. Running,
        // it asks for a frame on every display refresh — only while a
        // word-timed line is current, on a surface that is showing it.
        TimelineView(.animation(minimumInterval: nil, paused: !clockDriven)) { _ in
            // Reduce Motion asks for the state, not the travel: the line still
            // reads as the current one, it simply arrives lit rather than
            // filling.
            let drawn = reduceMotion ? 1 : (clockDriven ? clock?() ?? fraction : fraction)
            sweep(drawn, clockDriven: clockDriven)
        }
    }

    private func sweep(_ drawn: Double, clockDriven: Bool) -> some View {
        Text(text)
            .font(font)
            .tracking(tracking)
            // White on purpose, and never seen: the renderer multiplies it to the
            // colour each half of the line should be. Multiplying a colour that is
            // already dim would give a third, darker colour instead of the one
            // asked for.
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .textRenderer(
                KaraokeRenderer(fraction: drawn, accent: accent, base: base, fullWidth: fullWidth)
            )
            .animation(
                Self.sweepAnimation(reduceMotion: reduceMotion, clockDriven: clockDriven),
                value: drawn
            )
            .background(alignment: .leading) {
                // The same text on one row with nothing to stop it, never drawn,
                // only measured. A background so it takes no part in the line's
                // own layout, and outside the renderer so it is not swept.
                Text(text)
                    .font(font)
                    .tracking(tracking)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
    }
}

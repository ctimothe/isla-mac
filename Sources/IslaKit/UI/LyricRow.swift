import AppKit
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
    /// The whole song's text, when the surface has it. Present means the
    /// right-click menu can offer to copy all of it as well as this line.
    var allText: String?

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
        // Right-click, because copying a line is what a lyric is *for* and the
        // panel had no way to do it at all — the words were readable and not
        // quotable. A context menu rather than a control: it costs no pixels on
        // a surface that has none to give, and it is where a Mac user already
        // looks for "copy this".
        .contextMenu {
            Button(localized("Copy Line")) { Self.copy(line.text) }
            if let allText, !allText.isEmpty {
                Button(localized("Copy All Lyrics")) { Self.copy(allText) }
            }
        }
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// Plain text, and the pasteboard cleared first — without the clear, a copy
    /// leaves whatever richer flavour the last one wrote sitting underneath,
    /// and the paste takes that instead.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        } else {
            // The sung line lighting up is a motion, not a cut. This used to
            // swap a dim `Text` for a bright `KaraokeText` the instant the clock
            // crossed the line's timestamp — two views, no transition between
            // them — so on every surface the line change was the one thing that
            // did not move while the page under it did. The two now crossfade
            // on the lyric spring: the dim line fades as the bright one arrives,
            // which reads as the line lighting up in time with the voice, and
            // the brightening and the page's travel are one gesture because they
            // share one curve.
            ZStack(alignment: .leading) {
                if isCurrent {
                    KaraokeText(
                        text: line.text,
                        fraction: wordTimingEnabled
                            ? LyricSweep.fraction(line: line, at: at, end: end)
                            : 1,
                        reduceMotion: reduceMotion,
                        accent: accent,
                        font: .system(size: fontSize, weight: weight),
                        tracking: Theme.tracking(forSize: fontSize),
                        // Brighter than any neighbour even before the sweep
                        // arrives: the line being sung must never be the darkest
                        // thing on screen.
                        base: .white.opacity(0.5),
                        lineLimit: lineLimit
                    )
                    .transition(.opacity)
                } else {
                    // Depth through opacity alone. An early cut blurred and
                    // fractionally scaled these, which at reading size is not
                    // depth — it is smeared type, because subpixel scaling
                    // rasterises every glyph soft. Clamped to `falloffFloor`,
                    // never the bare 0.18: without the clamp the far lines sat
                    // at 1.54:1, unreadable as text.
                    Text(line.text)
                        .islandFont(fontSize, weight: weight)
                        .foregroundStyle(.white.opacity(falloffOpacity))
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
            .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: isCurrent)
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

/// The next line arriving in a one-line slot — the caption on the panel — as a
/// turn rather than a crossfade.
///
/// The new line rises into the slot from just below while the one it replaces
/// lifts out above it, each softening as it goes: the way the system's own
/// island swaps what it is showing, and the way a page of lyrics moves when
/// the whole page is on screen. A crossfade in place was the one motion on the
/// panel that told the eye nothing had moved, when the song had.
struct LyricLineTurn: ViewModifier {
    /// 1 while absent, 0 once arrived.
    let progress: Double
    /// +1 for a line arriving from below, −1 for one leaving upward.
    let direction: CGFloat

    /// Under half the caption slot: enough to read as travel, not enough to
    /// leave the slot before the clip takes it. `MotionValuesTests` holds the
    /// relation to `MediaPane.captionHeight`.
    static let travel: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .offset(y: progress * Self.travel * direction)
            .blur(radius: progress * 3)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    /// One line giving way to the next. Reduce Motion keeps the change and
    /// drops the travel, as every reduced variant here does.
    static func lyricLine(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: LyricLineTurn(progress: 1, direction: 1),
                identity: LyricLineTurn(progress: 0, direction: 1)
            ),
            removal: .modifier(
                active: LyricLineTurn(progress: 1, direction: -1),
                identity: LyricLineTurn(progress: 0, direction: -1)
            )
        )
    }
}

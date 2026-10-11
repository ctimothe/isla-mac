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
    /// The moment to sweep against, read afresh on every display frame, lead
    /// already applied — `LyricSweep.frameClock`. `at` is the published
    /// moment, as old as the last 0.1 s tick; this is where the clock is now.
    /// Nil while the song is paused, and the sweep then stands at `at`.
    var clock: (@MainActor () -> TimeInterval)? = nil

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
    /// The reader has scrolled away by hand. Every line on screen is then
    /// something being read rather than context around the voice, so none is
    /// dimmed to depth — the way the system's own lyrics clear as soon as a
    /// finger moves them, and settle back once the page follows the song again.
    var reading = false
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

    /// Every line while the reader scrolls by hand: bright enough to read as
    /// text rather than as depth — 0.46 is the panel's own tertiary label at
    /// 4.58:1 — and still under the 0.5 the sung line's unsung words sit at,
    /// so the line being sung is never the dimmer one even then.
    static func readingOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.48 : 0.46
    }

    /// The opacity of a row that is not lit: everything at reading strength
    /// while the reader scrolls by hand, the neighbour one step from the lit
    /// row, the floor for everything further out. One function so a line and
    /// an interlude marker at the same depth are the same grey.
    static func contextOpacity(distance: Int, reading: Bool, increaseContrast: Bool) -> Double {
        if reading { return readingOpacity(increaseContrast: increaseContrast) }
        guard distance != 1 else { return neighbourOpacity(increaseContrast: increaseContrast) }
        return falloffFloor(increaseContrast: increaseContrast)
    }

    /// What the lit row is drawn at before the voice fills it: the sung
    /// line's unsung words, and the interlude marker while it plays. Above
    /// every context opacity at every setting, so the row the song is in is
    /// never the dimmer one.
    static let litBaseOpacity: Double = 0.5

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
                        // The same function the lab's resolutions report, so
                        // the sweep a surface claims is the sweep it draws.
                        fraction: LyricSweep.drawnFraction(
                            line: line, isCurrent: true, at: at, end: end,
                            wordTiming: wordTimingEnabled
                        ),
                        // The same function again, asked by the frame rather
                        // than by the tick, and only for a line whose sweep
                        // moves at all: a line-timed row is lit whole and
                        // needs no frame callback to stay so.
                        clock: LyricSweep.liveFraction(
                            line: line, end: end, wordTiming: wordTimingEnabled, clock: clock
                        ),
                        reduceMotion: reduceMotion,
                        accent: accent,
                        font: .system(size: fontSize, weight: weight),
                        tracking: Theme.tracking(forSize: fontSize),
                        // Brighter than any neighbour even before the sweep
                        // arrives: the line being sung must never be the darkest
                        // thing on screen.
                        base: .white.opacity(Self.litBaseOpacity),
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
        Self.contextOpacity(
            distance: distance, reading: reading,
            increaseContrast: SystemAppearance.shared.increaseContrast
        )
    }
}

/// The silence before a line, drawn as a row of its own: a note and a short
/// track that fills from the moment the voice stopped to the moment it comes
/// back.
///
/// After LY-05 a line goes dark at its end, and a twenty-second solo showed
/// only the next line, dim, waiting at the reading centre — which reads as the
/// lyrics having lost the song (M-36). The visual lab's render of the same
/// break was a blank selected row that VoiceOver read as a button with no
/// name (H-011). This says what is happening and how long is left, and it is
/// named.
///
/// A fill, not Apple Music's breathing dots: a slow loop for as long as a solo
/// lasts is the decorative motion the apple-design skill warns against, and a
/// fill tells the one thing worth knowing — when the words come back. Nothing
/// here loops at any setting. The fill is placed by the clock on each frame
/// while the song plays, the way `KaraokeText` places its edge, and under
/// Reduce Motion it moves only with the published position, a step at a time,
/// with no animation between.
///
/// Drawn in the line's own greys — `LyricRow.contextOpacity` while another row
/// is lit, the lit row's base while it plays — so it sits in the page's depth
/// rather than on top of it.
struct InterludeMarker: View {
    /// How far through the interlude the clock is, 0 to 1, as last published.
    let progress: Double
    /// Whether this is the interlude playing now.
    let isCurrent: Bool
    /// How many rows away from the lit one, for the depth falloff.
    let distance: Int
    /// The progress read afresh on every display frame, or nil to draw
    /// `progress` as it is. Handed in only while this interlude plays and the
    /// song moves, so a marker nobody is waiting through costs no frames.
    var clock: (@MainActor () -> Double)? = nil
    /// The line's own type size, so the note sits on the same baseline and
    /// the row is exactly as tall as a one-line lyric beside it.
    var fontSize: CGFloat = Theme.TypeRole.title.size
    var weight: Font.Weight = .bold
    var reading = false
    var reduceMotion = false

    /// How long the track is. Short on purpose: a progress bar the width of
    /// a lyric would read as a second scrubber, and this is a rest in the
    /// text, not a control.
    static let trackWidth: CGFloat = 44
    /// A point thinner than the panel's 4 pt scrubber, so the two read as one
    /// family and the marker is never taken for a second place to seek.
    static let trackHeight: CGFloat = 3

    /// What VoiceOver hears for the row.
    static var accessibilityLabel: String { localized("Instrumental") }

    /// How much of the track is filled for a progress, clamped so a clock
    /// read past either end never draws outside the track.
    static func filledWidth(progress: Double) -> CGFloat {
        trackWidth * CGFloat(min(max(progress, 0), 1))
    }

    var body: some View {
        let clockDriven = clock != nil && !reduceMotion
        let tone = Color.white.opacity(opacity)
        HStack(spacing: 8) {
            // An image inside a `Text`, so the row takes a text line's height
            // at this size: on the lock card the window's rows are measured
            // by their type, and a symbol image framed on its own came out a
            // few points shorter and moved every line below it.
            Text(Image(systemName: "music.note"))
                .islandFont(fontSize, weight: weight)
                .foregroundStyle(tone)
            // One timeline always, paused unless the clock drives it, as in
            // `KaraokeText`: a marker that starts or stops playing keeps its
            // identity rather than being swapped mid-solo.
            TimelineView(.animation(minimumInterval: nil, paused: !clockDriven)) { _ in
                let drawn = clockDriven ? clock?() ?? progress : progress
                Capsule()
                    .fill(Theme.hairline)
                    .frame(width: Self.trackWidth, height: Self.trackHeight)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tone)
                            .frame(width: Self.filledWidth(progress: drawn), height: Self.trackHeight)
                    }
                    // Never interpolated. The stage turns its page in an
                    // animated transaction, and carried along with it the
                    // fill would ease behind the clock it is drawn from.
                    .transaction { $0.animation = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: isCurrent)
        // One element with a name, not a button: there is no line here to
        // jump to, and H-011's dump was exactly a nameless selected button.
        // Static text, so the element has a role as well as a name: left
        // bare, the visual lab's dump read it as AXUnknown.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? [.isStaticText, .isSelected] : [.isStaticText])
    }

    @MainActor
    private var opacity: Double {
        isCurrent
            ? LyricRow.litBaseOpacity
            : LyricRow.contextOpacity(
                distance: distance, reading: reading,
                increaseContrast: SystemAppearance.shared.increaseContrast
            )
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

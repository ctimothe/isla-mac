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
    /// The weight of a line that is not being sung, when it differs from the
    /// sung line's: the column draws the sung line bold and the rest semibold
    /// (spec §2.2), the tall page bold throughout. Nil is `weight`, which is
    /// what the stage and the lock card always did.
    var contextWeight: Font.Weight? = nil
    var lineLimit: Int = 1
    var accent: Color = .white
    var reduceMotion: Bool = false
    /// A line timeline, or an unmeasured player clock, highlights the whole
    /// current line. It must never animate a made-up word progression.
    var wordTimingEnabled = false
    /// What the row is drawn over, and so which `Ramp` of greys it takes. A
    /// surface rather than a ramp because the row reads Increase Contrast
    /// itself, at draw time, the way it always has: a ramp handed in by the
    /// caller would be the setting as it stood when the caller last ran.
    var surface: Surface = .panel
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
    /// "Sync Here": the voice is singing this line right now, so make it the
    /// current one (`LyricsStore.syncTrackOffset`). Present only on the stage.
    /// The lock card hands none, and offers no such item: it is a glance at
    /// the song, and a correction made there would be made blind to the
    /// panel's own Reset.
    var syncHere: (() -> Void)?
    /// Where this row stands against the sung one, for the stage's own depth
    /// (spec §19.6): a signed row offset, because the board dims the lines above
    /// the sung one differently from the lines below it. Nil keeps the
    /// symmetric `Ramp.context` falloff, which is what the lock card uses.
    var board: BoardDepth? = nil
    /// The translation drawn under the line (spec §5.3), or nil. Plain text in
    /// the board's own sizes (`PlayerLayout.translationStyle`) and brightness
    /// (`translationOpacity`): the sung line's translation sweeps nothing, so a
    /// song with word timing never has two things moving in one row. Needs
    /// `board`, the stage's, and is ignored without it, which is what the lock
    /// card's rows are.
    var translation: String? = nil
    /// What to draw as the line itself when it is not the whole of `line.text`:
    /// a bilingual file's first row, its second being the translation. Nil is
    /// `line.text`, as every surface drew until the redesign.
    var displayText: String? = nil

    struct BoardDepth: Equatable {
        /// Rows from the sung row, negative above it.
        let offset: Int
    }

    enum Surface {
        /// The island's own black.
        case panel
        /// The lock card, lit from behind by the song's cover.
        case card

        func ramp(increaseContrast: Bool) -> Ramp {
            switch self {
            case .panel: .panel(increaseContrast: increaseContrast)
            case .card: .card(increaseContrast: increaseContrast)
            }
        }
    }

    /// The greys a lyric is drawn in, from the far context lines up to the
    /// sung line's unsung words — one set per surface, because the panel and
    /// the card sit on different backdrops.
    ///
    /// Depth is opacity alone and these are its steps; the sung words arrive
    /// at full white through `KaraokeText`. Blurring the far lines by distance
    /// was weighed and rejected: an early cut did that, and at reading size it
    /// was smeared type rather than depth.
    struct Ramp: Equatable {
        /// The dimmest a context line may go: every line two or more rows
        /// from the lit one.
        let floor: Double
        /// The line one step from the lit one.
        let neighbour: Double
        /// The lit row before the voice fills it: the sung line's unsung
        /// words, and the interlude marker while it plays. Above every other
        /// step, so the row the song is in is never the dimmest thing on
        /// screen.
        let unswept: Double
        /// Every line while the reader scrolls by hand: read as text rather
        /// than as depth, and still under `unswept`.
        let reading: Double

        /// Over the panel's black.
        ///
        /// The floor was 0.28 (2.27:1 over black) and the neighbour 0.34
        /// (2.89:1), by a recorded preference for depth over contrast; both
        /// were under WCAG's 3:1 even for the large type a lyric is set in
        /// (owner decision 9). They are 0.36 (3.13:1) and 0.42 (3.95:1) now,
        /// and 0.42 (3.95:1) and 0.46 (4.58:1) under Increase Contrast. Depth
        /// still reads as four steps — 0.36, 0.42, 0.50, full white — and the
        /// floor and the neighbour stay apart at both settings: the neighbour
        /// once sat *below* the floor under Increase Contrast, the near line
        /// dimmer than the far ones (`testLyricNeighbourSitsAboveTheFalloffFloor`).
        /// Reading stays at 0.46, the panel's own tertiary label at 4.58:1.
        static func panel(increaseContrast: Bool) -> Ramp {
            increaseContrast
                ? Ramp(floor: 0.42, neighbour: 0.46, unswept: 0.50, reading: 0.48)
                : Ramp(floor: 0.36, neighbour: 0.42, unswept: 0.50, reading: 0.46)
        }

        /// Over the lock card, which is lit by the song's cover.
        ///
        /// The card drew the panel's greys, which were tuned against black,
        /// over a backdrop that `LockCardLegibility` only guarantees to be dark
        /// enough for `Theme.cardTertiary` — and in the visual lab's light
        /// renders the context lines dissolved into a pale cover (about 2.1:1
        /// for the floor, 2.5:1 for the neighbour). The card's ramp starts
        /// where its own type does: the neighbour is `cardTertiary`, so over
        /// the palest cover it clears AA exactly as the times beside it do,
        /// and the floor sits one step under it and still holds 3:1. The
        /// unswept words step up to `cardSecondary`, the artist line's grey.
        /// `testCardLyricsHoldOverTheBrightestCover` measures every step over
        /// a white cover in both styles the cover lights.
        static func card(increaseContrast: Bool) -> Ramp {
            // The tokens themselves rather than their values today (0.62 and
            // 0.75; 0.75 and 0.85 under Increase Contrast): the wash is solved
            // for `cardTertiary`, so a neighbour that follows the token keeps
            // its AA if the token ever moves.
            let tertiary = Theme.cardTertiaryOpacity(increaseContrast: increaseContrast)
            return Ramp(
                floor: increaseContrast ? 0.62 : 0.50,
                neighbour: tertiary,
                unswept: Theme.cardSecondaryOpacity(increaseContrast: increaseContrast),
                // The card has no reading mode — it holds a window of the song
                // and never scrolls by hand — so this is only ever the
                // neighbour's grey, for completeness.
                reading: tertiary
            )
        }

        /// The opacity of a row that is not lit: everything at reading
        /// strength while the reader scrolls by hand, the neighbour one step
        /// from the lit row, the floor for everything further out. One
        /// function so a line and an interlude marker at the same depth are
        /// the same grey.
        func context(distance: Int, reading isReading: Bool) -> Double {
            if isReading { return reading }
            return distance == 1 ? neighbour : floor
        }
    }

    // The panel's steps by name, kept because the contrast and display tests
    // were written against them. Each is the ramp, not a second copy of its
    // numbers.

    static func falloffFloor(increaseContrast: Bool) -> Double {
        Ramp.panel(increaseContrast: increaseContrast).floor
    }

    static func neighbourOpacity(increaseContrast: Bool) -> Double {
        Ramp.panel(increaseContrast: increaseContrast).neighbour
    }

    static func readingOpacity(increaseContrast: Bool) -> Double {
        Ramp.panel(increaseContrast: increaseContrast).reading
    }

    /// A credit's weight, whatever the caller asked of the lyric. Both
    /// surfaces pass `.bold`, and the credit branch used to hand that straight
    /// through under a comment saying "never bold" — so "Produced by" came out
    /// bold italic, dressed as the line being sung (F-051).
    static let creditWeight: Font.Weight = .medium

    /// A credit's grey: lit like the row the song is in while it is the
    /// current one, and otherwise a context line at the ramp's floor. It was a
    /// fixed 0.34 (2.89:1) that Increase Contrast never moved.
    static func creditOpacity(isCurrent: Bool, ramp: Ramp) -> Double {
        // Never under the ramp's unswept step: on the card, whose steps run
        // brighter, a fixed 0.68 would have left the current credit dimmer
        // than an ordinary lit line.
        isCurrent ? max(0.68, ramp.unswept) : ramp.floor
    }

    static func creditOpacity(isCurrent: Bool, increaseContrast: Bool) -> Double {
        creditOpacity(isCurrent: isCurrent, ramp: .panel(increaseContrast: increaseContrast))
    }

    var body: some View {
        Button { seek?() } label: {
            VStack(alignment: .leading, spacing: Self.translationGap) {
                content
                translationRow
            }
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
            if let syncHere {
                Divider()
                Button(localized("Sync Here"), action: syncHere)
            }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        // The menu is a pointer's way in; VoiceOver and Switch Control reach
        // the same item as a named action on the row.
        .modifier(SyncHereAction(action: syncHere))
    }

    /// The air between a line and its translation: 2 pt, the board's gap at both
    /// sizes (`Ct` 89 → 107 under a 13 pt line, `Tt` 188 → 212 under 17).
    static let translationGap: CGFloat = 2

    /// What VoiceOver reads: the line, then its translation as a second
    /// sentence — one element per row, as the line always was.
    private var accessibilityText: String {
        guard let translation else { return line.text }
        return [displayText ?? line.text, translation].joined(separator: ". ")
    }

    @MainActor
    @ViewBuilder
    private var translationRow: some View {
        if let translation, board != nil, !line.isCredit {
            let style = PlayerLayout.translationStyle(isSung: isCurrent)
            Text(translation)
                .islandFont(style.size, weight: style.weight)
                .foregroundStyle(.white.opacity(PlayerLayout.translationOpacity(
                    isSung: isCurrent, increaseContrast: SystemAppearance.shared.increaseContrast
                )))
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity)
        }
    }

    /// Adds the "Sync Here" accessibility action only where a handler exists.
    /// A modifier of its own because `accessibilityAction` cannot be applied
    /// conditionally in place.
    private struct SyncHereAction: ViewModifier {
        let action: (() -> Void)?

        func body(content: Content) -> some View {
            if let action {
                content.accessibilityAction(named: localized("Sync Here"), action)
            } else {
                content
            }
        }
    }

    /// Plain text, and the pasteboard cleared first — without the clear, a copy
    /// leaves whatever richer flavour the last one wrote sitting underneath,
    /// and the paste takes that instead.
    @MainActor
    static func copy(_ text: String) {
        let pasteboard = PasteboardRead.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    @ViewBuilder
    private var content: some View {
        if line.isCredit {
            // Never swept, never bold. A credit is on screen because the song
            // has not started, and dressing it as the current lyric would claim
            // somebody is singing "Produced by". The weight is the row's own,
            // not the caller's: the caller's is the lyric's, and it is bold.
            Text(line.text)
                .islandFont(fontSize, weight: Self.creditWeight)
                .italic()
                .foregroundStyle(.white.opacity(Self.creditOpacity(isCurrent: isCurrent, ramp: ramp)))
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
                        text: displayText ?? line.text,
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
                        // thing on screen. The surface's own step, so on the
                        // card — whose neighbour is 0.62 — the sung line's
                        // unsung words do not fall under it at the panel's 0.5.
                        base: .white.opacity(ramp.unswept),
                        lineLimit: lineLimit
                    )
                    .transition(.opacity)
                } else {
                    // Depth through opacity alone. An early cut blurred and
                    // fractionally scaled these, which at reading size is not
                    // depth — it is smeared type, because subpixel scaling
                    // rasterises every glyph soft. Clamped to the ramp's floor,
                    // never the bare 0.18: without the clamp the far lines sat
                    // at 1.54:1, unreadable as text.
                    Text(displayText ?? line.text)
                        .islandFont(fontSize, weight: contextWeight ?? weight)
                        .foregroundStyle(.white.opacity(contextOpacity))
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
            .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: isCurrent)
        }
    }

    /// The opacity of a line that is not being sung: the board's (raised to the
    /// ramp's floor, `PlayerLayout.lyricOpacity`) where the row knows its signed
    /// offset, the symmetric falloff where it does not.
    @MainActor
    private var contextOpacity: Double {
        if let board {
            return PlayerLayout.lyricOpacity(offset: board.offset, ramp: ramp, reading: reading)
        }
        return ramp.context(distance: distance, reading: reading)
    }

    /// This surface's steps at the setting as it stands now. The floor always
    /// clears the old 0.18, so no `max` guard is needed — the clamp *is* the
    /// value.
    @MainActor
    private var ramp: Ramp {
        surface.ramp(increaseContrast: SystemAppearance.shared.increaseContrast)
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
/// Drawn in the line's own greys — its surface's `LyricRow.Ramp` context step
/// while another row is lit, the ramp's unswept step while it plays — so it
/// sits in the page's depth rather than on top of it.
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
    /// The same surface as the lines around it, so on the lock card a marker
    /// is the card's grey and not the panel's dimmer one beside a card line.
    var surface: LyricRow.Surface = .panel
    /// What the rest looks like. The lock card keeps the note and the filling
    /// track; the panel's column and tall page draw three dots (spec §5.4,
    /// `Lyrics-Instrumental`): 7 pt, at 0.9, 0.55 and 0.3, left-aligned where
    /// the sung line goes.
    var style: Style = .track

    enum Style: Equatable {
        case track
        case dots
    }

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
        if style == .dots {
            dots
        } else {
            track
        }
    }

    /// Three static dots. The current interlude shows them at the board's own
    /// strengths; one the song has passed or has yet to reach is the same three
    /// dimmed to its row's context step, so the page's depth reaches it. They do
    /// not animate and carry no progress: a rest is not a loading state, and the
    /// words coming back is the next row down.
    @MainActor
    private var dots: some View {
        let scale = isCurrent ? 1 : opacity / max(surface.ramp(increaseContrast: SystemAppearance.shared.increaseContrast).unswept, 0.01)
        return HStack(spacing: Theme.instrumentalDotSpacing) {
            ForEach(Array(Theme.instrumentalDotOpacities.enumerated()), id: \.offset) { _, level in
                Circle()
                    .fill(Color.white.opacity(level * min(scale, 1)))
                    .frame(width: Theme.instrumentalDotSize, height: Theme.instrumentalDotSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: isCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? [.isStaticText, .isSelected] : [.isStaticText])
    }

    @MainActor
    private var track: some View {
        let clockDriven = clock != nil && !reduceMotion
        let tone = Color.white.opacity(opacity)
        return HStack(spacing: 8) {
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
        let ramp = surface.ramp(increaseContrast: SystemAppearance.shared.increaseContrast)
        return isCurrent ? ramp.unswept : ramp.context(distance: distance, reading: reading)
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

    /// The softening a line wears while fully away. It was 3 pt, and with
    /// both lines half there at once the blur is what turned an overlap into
    /// a smear (H-014); 2 pt still reads as the line going out of focus
    /// rather than sliding as a sharp block.
    static let maxBlur: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .offset(y: progress * Self.travel * direction)
            .blur(radius: progress * Self.maxBlur)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    /// One line giving way to the next. Reduce Motion keeps the change and
    /// drops the travel, as every reduced variant here does.
    ///
    /// Each side carries its own curve (`Theme.captionTurnOut` and
    /// `captionTurnIn`), which overrides whatever animation the line change
    /// arrived in — the caller's `lyricScroll` on the line index — for the
    /// turn only. On that one shared spring both lines crossed at once and
    /// printed over each other for about 97 ms of every turn (H-014). The
    /// reduced variant stays a plain crossfade on the caller's 0.12 s ease:
    /// no travel and no blur, so the overlap is two sharp lines for a few
    /// frames rather than a smear sliding across them.
    static func lyricLine(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: LyricLineTurn(progress: 1, direction: 1),
                identity: LyricLineTurn(progress: 0, direction: 1)
            ).animation(Theme.captionTurnIn),
            removal: .modifier(
                active: LyricLineTurn(progress: 1, direction: -1),
                identity: LyricLineTurn(progress: 0, direction: -1)
            ).animation(Theme.captionTurnOut)
        )
    }
}

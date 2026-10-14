import SwiftUI

/// The lyric area: every line, scrolling with the voice, and what stands in
/// for the lines when there are none.
///
/// Until the redesign (2026-10-15, spec §5) this was a page of its own with a
/// header of utilities, a blurred cover behind it and a back chevron. It is now
/// the lyric region of the player's other two states — the column beside the
/// controls and the tall page above them — and everything that was the page's
/// own furniture has moved to where the spec puts it: the timing nudge, import,
/// edit, unbind and search-again live in the More menu in the panel's header
/// (`LyricsMoreMenuController`), the way back is the Lyrics button, and the
/// ground is the panel's black.
///
/// What a *line* does has not changed, and it is all still here. The caption
/// said *what is being sung now*; this says *where the song is* — the sung line
/// sweeping word by word, the next ones waiting, all riding the same position
/// clock that keeps the caption honest. Reading position is fixed: the sung
/// line lives at one place in the area (`readingCentre`) and the *text* moves
/// through it, which is how every karaoke surface since the bouncing ball has
/// worked, because eyes stay still while singing.
///
/// Every line is a button: tapping one seeks the song there; a right-click
/// copies or syncs it. A hand on the scroll wheel stops the page following the
/// song, and the Sync pill brings it back.
struct LyricsStage: View {
    /// Which of the player's two lyric states the area is in: the column beside
    /// the controls (13 pt, 23 pt apart) or the tall page above them (17 pt,
    /// 34 pt apart). The defaults are the tall page's, which is what an
    /// unconfigured stage — the render tests', the lab's — has always been the
    /// nearest thing to.
    enum Mode: Equatable {
        case column
        case tall

        var metrics: Metrics { self == .column ? .column : .tall }
    }

    /// What a mode sets in type and in space (spec §5.1). One value per mode, so
    /// the page's arithmetic — the slot every row occupies, which is what lets
    /// the clock map to a row by plain subtraction — reads from one place.
    struct Metrics: Equatable {
        /// Distance between two rows' tops: the fixed slot each occupies.
        let pitch: CGFloat
        /// The same with a translation under every line (spec §5.1, `Ct` and
        /// `Tt`): a line and its translation are one slot, 46 in the column and
        /// 52 on the tall page. Every slot takes it at once — an untranslated
        /// line (a credit, a line already in the target language) and an
        /// interlude included — so the page still maps the clock to a row by
        /// plain subtraction.
        let translatedPitch: CGFloat
        /// The size every line is set in. The sung line is never larger
        /// (decision 6): weight and brightness set it apart.
        let fontSize: CGFloat
        /// The sung line's weight, and the other lines'.
        let weight: Font.Weight
        let contextWeight: Font.Weight
        let tall: Bool

        static let column = Metrics(
            pitch: 23, translatedPitch: 46, fontSize: 13, weight: .bold, contextWeight: .semibold, tall: false
        )
        static let tall = Metrics(
            pitch: 34, translatedPitch: 52, fontSize: 17, weight: .bold, contextWeight: .bold, tall: true
        )

        /// The slot a row takes: one line, or a line over its translation.
        func slot(translated: Bool) -> CGFloat { translated ? translatedPitch : pitch }
    }

    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    var localLookup: LocalLyricsLookup? = nil
    var turnOnLyrics: () -> Void = {}
    var turnOnOnlineLyrics: () -> Void = {}
    var importLocalFile: () -> Void = {}
    /// Why the last Import from this page failed, said at the top of the area.
    /// Import used to fail in silence (G-007).
    var notice: String? = nil
    var selectLocalCandidate: (LocalLyricsCandidate) -> Void = { _ in }
    var removeLocalBinding: () -> Void = {}
    var editLocalLyrics: (LocalLyricsCandidate) -> Void = { _ in }
    /// Edit Lyrics… on a file that cannot be read: there is no document to open
    /// the editor on, so the host opens it on a blank one for this song.
    var editBlankLyrics: () -> Void = {}
    /// The line the parser names in a bound file it refused, for the unreadable
    /// state's sentence (spec §5.4); nil when it names none.
    var invalidLine: Int? = nil
    /// Kept so the stage can still be built as it was; the way back to the
    /// player is the Lyrics button now, which the host draws.
    var dismiss: () -> Void = {}
    var mode: Mode = .tall
    /// Whether Look Up Lyrics Online is on: decides whether a miss offers Search
    /// Online. The setting's own reading by default; a test hands in a value so
    /// the stage never reads the owner's preferences.
    var onlineEnabled: () -> Bool = { NotchViewModel.onlineLyricsEnabled }
    /// Where the sung line sits, measured from the top of this area (spec §5.1:
    /// y 96 in the column's body coordinates, 166 on the tall page). Nil centres
    /// it, which is what a stage with no board to follow does.
    var readingCentre: CGFloat? = nil
    /// The translated lines (spec §5.3). The session's service in the panel; the
    /// idle one — which translates nothing — everywhere a stage is drawn on its
    /// own. Observed, so the rows arrive together the moment its batch does.
    @ObservedObject var translation: LyricTranslation = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False once the reader has scrolled away under their own hand: the stage
    /// then stays where it was put, and the song moving on no longer drags the
    /// page out from under the eye. The sync pill puts it back.
    @State private var following = true
    /// The `LyricTranslation.demandEpoch` this stage raised its demand under.
    @State private var demandEpoch = 0
    /// The row sitting at the reading centre, as the scroll view itself
    /// reports it. Both the way the page is driven when it follows the song and
    /// the way it is read when it does not.
    ///
    /// A row, not the line's timestamp. Keyed by time, the two lines of a
    /// bilingual LRC — original and translation stamped at one moment —
    /// shared one id: one of them was drawn twice or skipped, and the page
    /// could not say which of them it was reading. A slot rather than a line
    /// index since interludes became rows of their own (M-36): through a solo
    /// the page rests on the interlude, which has no line index.
    @State private var reading: LyricSlot?

    /// White, always — the same rule the lock card follows. A sung line
    /// coloured from the cover is unreadable the moment the cover is pale.
    private let accent: Color = .white

    private var metrics: Metrics { mode.metrics }

    /// The one lead, shared with the caption and the lock card: the base plus
    /// all three offset layers, so a per-track nudge moves every surface.
    private var lead: TimeInterval {
        LyricSweep.lead(
            precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
            trackOffset: lyrics.trackOffset
        )
    }

    private var now: TimeInterval { media.position + lead }

    private var wordTimingEnabled: Bool {
        LyricsPresentation.usesWordTiming(
            lyrics.timingGranularity,
            precisionMeasured: media.precisionSync,
            wordKaraokeEnabled: lyrics.wordKaraokeEnabled
        )
    }

    private var inputs: LyricInputs {
        LyricInputs(
            position: media.position, precisionSync: media.precisionSync,
            userOffset: lyrics.userOffset, trackOffset: lyrics.trackOffset,
            wordTiming: wordTimingEnabled
        )
    }

    /// What the stage draws for one reading of the clock: the sung row (nil
    /// during an intro) and the row the page centres on. The caption and the
    /// lock card answer through the same `LyricSweep.resolve`, and the lyric
    /// lab calls this very function — the stage's arithmetic is not restated
    /// anywhere it could drift from.
    static func resolve(lines: [LyricsStore.Line], inputs: LyricInputs) -> LyricResolution {
        LyricSweep.resolve(lines: lines, inputs: inputs)
    }

    /// The identity of every row: its slot — a line by its index, an
    /// interlude by the line it leads to. See `reading` for why not a
    /// timestamp.
    static func rowIDs(_ lines: [LyricsStore.Line]) -> [LyricSlot] {
        LyricSweep.slots(for: lines)
    }

    /// What VoiceOver hears for a row: the line's words, or "Instrumental"
    /// for the silence before one. The visual lab's dump of a solo was a
    /// selected button with no name (H-011).
    static func accessibilityLabel(for slot: LyricSlot, in lines: [LyricsStore.Line]) -> String {
        switch slot {
        case .line(let index):
            return lines.indices.contains(index) ? lines[index].text : ""
        case .interlude:
            return InterludeMarker.accessibilityLabel
        }
    }

    /// What the area is showing for this song, through the one function the
    /// tests read.
    private var pageState: LyricsPageState {
        LyricsPageState.state(
            availability: lyrics.availability, lyricsState: lyrics.state, localLookup: localLookup,
            onlineEnabled: onlineEnabled(), invalidLine: invalidLine
        )
    }

    /// The text of the standing notice, if any. One row, one event: an import's
    /// failure is what the listener just did, so it speaks first; the version
    /// mismatch is a standing state and speaks when nothing else does. Never a
    /// toast as well.
    private var noticeContent: (icon: String, text: String)? {
        if let notice { return ("exclamationmark.circle", notice) }
        if lyrics.showsVersionMismatchNotice {
            return ("clock.arrow.circlepath", localized(
                "These lyrics are timed for a longer version of the song and may run late. Right-click the line being sung and choose Sync Here."
            ))
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let noticeContent {
                noticeRow(icon: noticeContent.icon, text: noticeContent.text)
            }
            if case .lines = pageState, case .synced(let lines) = lyrics.state {
                stage(lines: lines)
            } else {
                unavailable(pageState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Diagnostic readout, environment-gated like the open hook: says which
        // branch is live and why, in the corner, only when an agent launched
        // the binary with the variable set. Never present in a normal run.
        .overlay(alignment: .bottomLeading) {
            if DebugTrail.openLyrics {
                Text(debugStateDescription)
                    .font(Theme.TypeRole.caption.font().monospacedDigit())
                    .foregroundStyle(.yellow)
                    .padding(6)
                    // A readout is not a control. Left hittable it sat over the
                    // sync pill and swallowed every tap meant for it.
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            if DebugTrail.openLyrics {
                DebugTrail.note("stage appeared: \(debugStateDescription)")
            }
            // The lyric column or the tall page is on screen: translations are
            // wanted, and only now (spec §5.3; `LyricTranslation.setDemand`).
            demandEpoch = translation.demandEpoch
            translation.setDemand(.lyricArea, true)
        }
        // Lowered under the epoch it was raised in: after a rebuild reset the
        // demand, this view's late lowering must not cancel the new panel's.
        .onDisappear { translation.setDemand(.lyricArea, false, epoch: demandEpoch) }
        // Verification hook, environment-gated like the open hook: replays the
        // row button's exact statement on the line after the current one, then
        // samples the position for the backward yank this hook exists to catch.
        // Never armed in a normal run.
        .task {
            guard DebugTrail.testClickNext else { return }
            do {
                for round in 0..<5 {
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    guard case .synced(let lines) = lyrics.state,
                          let current = LyricSweep.index(in: lines, at: now),
                          current + 1 < lines.count else { continue }
                    let line = lines[current + 1]
                    DebugTrail.note("TEST[\(round)] click index=\(current + 1) at=\(line.at)")
                    media.seek(to: Self.clickTarget(lineAt: line.at, lead: lead, duration: media.duration))
                    for _ in 0..<10 {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        DebugTrail.note(String(format: "TEST[%d] pos=%.2f", round, media.position))
                    }
                }
                DebugTrail.note("TEST done")
            } catch {
                // Cancelled with the stage: a dismissed stage must not keep
                // seeking the player from beyond the grave.
            }
        }
        // The value is gated, not only the note: `onChange` evaluates what it
        // watches on every pass of this body, and the stage re-renders with
        // the position, so a normal run formatted a debug string for nobody.
        .onChange(of: DebugTrail.openLyrics ? debugStateDescription : "") { _, new in
            DebugTrail.note(new)
        }
    }

    private var debugStateDescription: String {
        let state: String
        switch lyrics.state {
        case .idle: state = "idle"
        case .loading: state = "loading"
        case .none: state = "none"
        case .synced(let lines): state = "synced(\(lines.count))"
        }
        return "\(state) pos=\(Int(media.position)) settled=\(media.positionSettled ? 1 : 0)"
    }

    // MARK: - Stage

    /// The signed row offset a line is given while nothing is lit — an intro, a
    /// breath too short to be an interlude, an outro.
    static let unlitOffset = 99

    /// The tall page's slot — 34 pt a row with no gap — which `centeringAir` and
    /// the visual lab's page-step keyframes measure against. The page was 40 pt
    /// rows 8 apart (48 pt a step) until the redesign; each mode's own pitch is
    /// `Metrics.pitch` now, 23 pt in the column and 34 on the tall page.
    static let slotHeight: CGFloat = Metrics.tall.pitch
    static let slotSpacing: CGFloat = 0

    /// Padding above the first line and below the last, so both ends can reach
    /// the reading centre. Half the viewport less half a slot; never negative,
    /// because a viewport shorter than one line would otherwise pull the whole
    /// column upward by the difference.
    static func centeringAir(viewport: CGFloat) -> CGFloat {
        max(0, viewport / 2 - slotHeight / 2)
    }

    /// Where the sung row's centre is held, measured from the top of the
    /// viewport. The board's y for the sung line less whatever a notice took off
    /// the top (`viewportCentre`); nil centres it. A centre that falls outside
    /// the middle of what is left — a notice in the narrow column can take most
    /// of the viewport — is held at 35 percent of it instead of off the page.
    static func holdingCentre(centre: CGFloat?, viewport: CGFloat) -> CGFloat {
        guard let centre, viewport > 0 else { return viewport / 2 }
        let fraction = centre / viewport
        guard fraction > 0.15, fraction < 0.85 else { return viewport * 0.35 }
        return centre
    }

    /// The unit point `scrollPosition(id:anchor:)` is given so that a row of
    /// height `slot` lands with its *centre* at `centre`.
    ///
    /// The anchor aligns the same unit point of the row with the same unit point
    /// of the viewport, so a row's centre lands at the anchor's own y only for
    /// 0.5; anywhere else it is off by `(0.5 − anchor) × slot` — 5 pt on the tall
    /// page at the board's y. Solving `anchor·H − anchor·slot + slot/2 = centre`
    /// for the anchor puts the centre where the board says.
    static func anchorUnit(centre: CGFloat, viewport: CGFloat, slot: CGFloat) -> CGFloat {
        guard viewport > slot else { return 0.5 }
        return min(max((centre - slot / 2) / (viewport - slot), 0), 1)
    }

    /// Air above the first row and below the last, for a reading centre at
    /// `centre`: what lets either end of the song reach it. Half a viewport less
    /// half a slot when the centre is the middle; never negative, because a
    /// viewport shorter than one line would otherwise pull the whole column
    /// upward by the difference.
    static func air(viewport: CGFloat, slot: CGFloat, centre: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (
            top: max(0, centre - slot / 2),
            bottom: max(0, viewport - centre - slot / 2)
        )
    }

    private func stage(lines: [LyricsStore.Line]) -> some View {
        let resolution = Self.resolve(lines: lines, inputs: inputs)
        let moment = resolution.moment
        let currentIndex = moment.current
        let slots = Self.rowIDs(lines)
        // Before the first line — an intro — the first line is the anchor:
        // waiting at the reading centre, dimmed, taking the sweep the moment
        // the voice arrives. Anchoring on nothing left the stage vacant.
        // Through an interlude long enough for a row of its own, including
        // an intro, the interlude is the anchor: the marker filling toward
        // the line coming sits where the eye already is.
        let anchor = moment.centreSlot
        let anchorIndex = LyricSweep.slotIndex(of: anchor, in: slots)
        let lit = LyricSweep.litSlotIndex(moment, in: slots)
        // The row under each line — a machine translation, or the second row of a
        // bilingual file — and with it the slot: every row takes the translated
        // pitch the moment any line carries one.
        let translations = translation.displayRows(for: lines)
        let translated = LyricTranslation.hasRows(translations)
        let pitch = metrics.slot(translated: translated)
        return GeometryReader { geo in
                // Air above the first line and below the last, so either end can
                // still reach the reading centre instead of stopping short
                // against the scroll bounds.
                let centre = Self.holdingCentre(centre: viewportCentre, viewport: geo.size.height)
                let unit = Self.anchorUnit(centre: centre, viewport: geo.size.height, slot: pitch)
                let air = Self.air(viewport: geo.size.height, slot: pitch, centre: centre)
                let strayed = Self.linesStrayed(
                    reading: reading.flatMap { slots.firstIndex(of: $0) }, from: anchorIndex
                )
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Every slot the same fixed height, an interlude as
                        // much as a line, so the page still maps the clock to
                        // a row by arithmetic.
                        ForEach(Array(slots.enumerated()), id: \.element) { position, slot in
                            Group {
                                switch slot {
                                case .line(let index):
                                    row(
                                        line: lines[index], index: index, moment: moment,
                                        distance: LyricSweep.distance(ofSlot: position, lit: lit),
                                        // With nothing lit every row sits at the far floor
                                        // (`LyricSweep.distance`): an offset far enough out
                                        // that the board has no row for it. Zero would be the
                                        // sung line's own, at full white.
                                        offset: lit.map { position - $0 } ?? Self.unlitOffset,
                                        lines: lines, translation: translations[index]
                                    )
                                case .interlude:
                                    interludeRow(
                                        slot, at: resolution.at, isCurrent: slot == moment.interlude,
                                        distance: LyricSweep.distance(ofSlot: position, lit: lit)
                                    )
                                }
                            }
                            .frame(height: pitch, alignment: .leading)
                            .id(slot)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, air.top)
                    .padding(.bottom, air.bottom)
                }
                .scrollPosition(id: $reading, anchor: UnitPoint(x: 0.5, y: unit))
                    // Lines dissolve at the viewport's edges instead of being
                    // guillotined mid-glyph by the clip.
                    .mask(edgeFade(height: geo.size.height))
                    // The song moving on carries the page with it — but only
                    // while nobody is reading ahead by hand.
                .onChange(of: anchor) { from, to in
                    if DebugTrail.openLyrics {
                        DebugTrail.note(String(
                            format: "STAGE anchor %d->%d current=%d now=%.2f slots=%d viewport=%.0f follow=%d strayed=%d",
                            slots.firstIndex(of: from) ?? -1, slots.firstIndex(of: to) ?? -1,
                            currentIndex ?? -1, now,
                            slots.count, geo.size.height, following ? 1 : 0, strayed))
                    }
                    guard following else { return }
                    center(on: to)
                }
                .onChange(of: following) { _, resumed in
                    guard resumed else { return }
                    center(on: anchor)
                }
                .onAppear { reading = anchor }
                    // A scroll wheel or two fingers on the trackpad is the one
                    // unambiguous statement of "I am reading, not watching":
                    // taken straight from the event stream rather than inferred
                    // from where the scroll view ended up, which cannot tell a
                    // hand from our own animation.
                .onScrollWheel {
                    guard following else { return }
                    following = false
                    if DebugTrail.openLyrics {
                        DebugTrail.note("STAGE reader took over")
                    }
                }
                // Only once the sung line has actually left the stage. A pill
                // that appears the instant the page moves is an alarm about
                // nothing: a line or two of drift still has the voice on
                // screen, and the way back is to keep reading.
                .overlay(alignment: .bottom) {
                    if !following, strayed >= Self.strayedEnoughToOfferSync {
                        syncPill
                            .padding(.bottom, 8)
                            .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
                    }
                }
                // With Reduce Motion on too: the pill's transition is already
                // plain opacity there, and the context lines dimming as the
                // reader takes over are opacity alone. Cut, the pill blinked
                // on in a single frame (F-055). A fade is not motion.
                .animation(Theme.contentAnimation, value: following)
                .animation(Theme.contentAnimation, value: strayed)
                // The translations arrive as one: the rows fade in together and
                // the slots take their new pitch on the same 0.16 s ease
                // (spec §5.3) — and on the 0.24 s crossfade under Reduce Motion
                // (§13), the one place this ease is not the right answer.
                .animation(reduceMotion ? Theme.reducedMotion : Theme.contentAnimation, value: translations)
        }
    }

    /// Where the sung line's centre sits measured from the top of the *viewport*
    /// — the area's reading centre less whatever a notice took off its top.
    /// Without a notice the viewport is the area, and this is `readingCentre`.
    private var viewportCentre: CGFloat? {
        guard let readingCentre else { return nil }
        guard noticeContent != nil else { return readingCentre }
        return readingCentre - noticeHeight
    }

    /// The notice's height: the board's 40, which holds two lines of 11 pt text
    /// at the tall page's width; in the narrower column the same words wrap to
    /// more lines and it grows to hold them.
    private var noticeHeight: CGFloat {
        mode == .column ? Self.columnNoticeHeight : Theme.mismatchNoticeHeight
    }

    /// The column's notice: 56, four lines of 11 pt at 1.3 under 10 pt of air
    /// either side would be 72; the text is held to three lines and the row to
    /// what they take.
    static let columnNoticeHeight: CGFloat = 56

    /// The soft edges, from the viewport's own height: about 22 pt at the top and
    /// 30 pt at the foot, never more than a quarter of it, so a short viewport
    /// keeps its middle.
    private func edgeFade(height: CGFloat) -> LinearGradient {
        let top = min(0.25, 22 / max(height, 1))
        let bottom = min(0.25, 30 / max(height, 1))
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: top),
                .init(color: .black, location: 1 - bottom),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Puts the sung line back at the reading centre.
    ///
    /// On `Theme.lyricScroll`, not on the generic content ease this used to
    /// borrow. `Theme.contentAnimation` is 0.16s — it is the curve for a badge
    /// appearing — and one page step here is a whole slot moved because the
    /// song moved. At 0.16s the page beat the thing it exists to carry:
    /// the new line was parked at the reading centre before the line it
    /// replaced had finished lighting up. The page has to be the slower motion,
    /// and it is the one animation in this app allowed a little overshoot —
    /// see the comment on `Theme.lyricScroll` for why the momentum rule permits
    /// exactly this one. The sweep inside a line is no longer an animation at
    /// all: `KaraokeText` places its edge from the clock on every frame, and
    /// refuses the transaction this page turn runs in.
    ///
    /// The Reduce Motion branch is now inside `Theme.lyricScroll(reduceMotion:)`
    /// rather than being a bare assignment here. It still refuses the spring —
    /// what it no longer does is snap the page between lines with no transition
    /// at all, which is the same answer `Theme.open(reduceMotion:)` gives.
    private func center(on id: LyricSlot) {
        withAnimation(Theme.lyricScroll(reduceMotion: reduceMotion)) { reading = id }
    }

    /// The song as somebody would paste it: the sung lines, in order, one per
    /// line, with the credits left out — they are metadata the app inferred,
    /// not words anybody sang.
    static func plainText(_ lines: [LyricsStore.Line]) -> String {
        lines.filter { !$0.isCredit }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// How far the page may drift before the way back is worth offering: the
    /// column shows about five lines and the tall page about eight, so one line
    /// either side of the sung one is still in view and needs no rescuing.
    static let strayedEnoughToOfferSync = 2

    /// Rows between the row being read and the row being sung. Plain index
    /// arithmetic now that the page reports a row rather than a timestamp it
    /// had to search back into a row. Rows are slots, so an interlude counts
    /// as one: it takes a row of the page like any line.
    static func linesStrayed(reading: Int?, from anchor: Int) -> Int {
        guard let reading else { return 0 }
        return abs(reading - anchor)
    }

    /// The way back to the song after reading ahead — Spotify's affordance, and
    /// the only honest one: a page that yanks itself back on a timer takes the
    /// line away mid-sentence.
    ///
    /// A solid capsule, 74 × 24 (spec §5.4, `Lyrics-Sync`): `#3A3A3C` at 0.96, a
    /// hairline and a soft shadow. Solid because it sits inside an opaque panel
    /// with nothing behind it for glass to sample.
    private var syncPill: some View {
        Button {
            if DebugTrail.openLyrics {
                DebugTrail.note("SYNC tapped")
            }
            following = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                Text(localized("Sync"))
                    .islandFont(11.5, weight: .semibold)
            }
            .foregroundStyle(.white)
            .frame(width: Theme.syncPillSize.width, height: Theme.syncPillSize.height)
            .background(Theme.syncPillFill, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel(localized("Back to the current line"))
        .help(localized("Back to the current line"))
    }

    private func row(
        line: LyricsStore.Line, index: Int, moment: LyricMoment, distance: Int, offset: Int,
        lines: [LyricsStore.Line], translation: String?
    ) -> some View {
        let current = moment.current
        let isCurrent = index == current
        return LyricRow(
            line: line,
            isCurrent: isCurrent,
            // How far from the lit row this line stands, in rows, for the
            // depth falloff (`LyricSweep.distance(ofSlot:lit:)`).
            distance: distance,
            at: now,
            end: LyricSweep.end(of: index, in: lines),
            // Only the sung row reads the clock per frame; every other row is
            // lit whole or not at all.
            clock: isCurrent ? LyricSweep.frameClock(media: media, lead: lead) : nil,
            // The area reads at the mode's size, one line to a slot: the column
            // at 13 pt and the tall page at 17, the sung line bold at full
            // white and never larger (decision 6). A longer line is cut at its
            // tail, its full words still what VoiceOver reads.
            fontSize: metrics.fontSize,
            weight: metrics.weight,
            contextWeight: metrics.contextWeight,
            lineLimit: 1,
            accent: accent,
            reduceMotion: reduceMotion,
            wordTimingEnabled: wordTimingEnabled,
            reading: !following,
            seek: {
                if DebugTrail.openLyrics {
                    DebugTrail.note(String(
                        format: "ROW CLICK index=%d at=%.2f current=%d pos=%.2f",
                        index, line.at, current ?? -1, media.position
                    ))
                }
                Haptics.alignment()
                media.seek(to: Self.clickTarget(lineAt: line.at, lead: lead, duration: media.duration))
                // Choosing a line is choosing the song's place in it: the page
                // follows again from there rather than stranding the reader one
                // tap away from a stage that no longer moves.
                following = true
            },
            allText: Self.plainText(lines),
            // A credit is metadata the app inferred, not a line anybody
            // sang, so it is no line to sync to.
            syncHere: line.isCredit ? nil : {
                syncHere(toLineAt: line.at)
            },
            // The board's own depth: lines above the sung one dimmer than the
            // lines below it, raised where the contrast floor needs it.
            board: .init(offset: offset, tall: metrics.tall),
            translation: translation,
            // A bilingual line is drawn as its first row alone; the second is
            // the translation row under it, or hidden with the rest.
            displayText: LyricTranslation.rows(of: line.text).secondary == nil
                ? nil : LyricTranslation.rows(of: line.text).primary
        )
        .frame(maxHeight: .infinity, alignment: .center)
        // A row lighting is depth through opacity alone — `LyricRow` gave up
        // its blur and scale — so it brightens under Reduce Motion as well
        // rather than switching on in one frame (F-055).
        .animation(Theme.contentAnimation, value: isCurrent)
        .accessibilityHint(localized("Jumps the song to this line"))
    }

    /// "Sync Here" on a row: the voice is on this line now, so this track's
    /// delay becomes the one that makes it current at this moment. The clock
    /// is read at the click, extrapolated rather than the last published
    /// tick, which is up to 0.1 s old. The page follows again afterwards,
    /// since the sung line has just moved under the reader.
    private func syncHere(toLineAt lineAt: TimeInterval) {
        lyrics.syncTrackOffset(
            toLineAt: lineAt, position: media.extrapolatedPosition(), precisionSync: media.precisionSync
        )
        following = true
    }

    /// The silence before a line, in the slot a line would take: three dots
    /// where the sung line goes (spec §5.4). No seek and no hint: there are no
    /// words here to jump to, and the line it leads to is the next row down.
    private func interludeRow(_ slot: LyricSlot, at: TimeInterval, isCurrent: Bool, distance: Int) -> some View {
        InterludeMarker(
            progress: LyricSweep.interludeProgress(slot, at: at),
            isCurrent: isCurrent,
            distance: distance,
            // Only the interlude playing reads the clock per frame — and the
            // dots, which carry no progress, have no use for it.
            clock: nil,
            fontSize: metrics.fontSize,
            weight: metrics.weight,
            reading: !following,
            reduceMotion: reduceMotion,
            style: .dots
        )
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Notice

    /// One quiet notice at the top of the area (spec §5.4, `Lyrics-Version-
    /// Mismatch`): 40 tall in the tall page's width, radius 9, white 0.07 with a
    /// hairline, a `clock.arrow.circlepath` at 12 pt and the existing words at
    /// 11 pt, wrapping. It takes the room it needs from the lines below rather
    /// than covering a lyric. VoiceOver hears it from `NotchViewModel`, which
    /// raised it.
    private func noticeRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 1)
            Text(text)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(.white)
                .lineSpacing(1.5)
                .lineLimit(mode == .column ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: noticeHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.mismatchNoticeRadius, style: .continuous)
                .fill(Theme.mismatchNoticeFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.mismatchNoticeRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - States (spec §5.4)

    /// What stands where the lines would: centred in the area, one glyph or
    /// spinner, one sentence in 12 pt medium, and the way out of the dead end on
    /// the page that shows it. Both used to point at Settings, which a Spotify
    /// listener, the commonest one, had to visit twice before any word appeared.
    @ViewBuilder
    private func unavailable(_ state: LyricsPageState) -> some View {
        VStack(spacing: 8) {
            switch state {
            case .lines, .resolving:
                // Nothing at all while the answer is still quick. A glyph and a
                // blank caption for a fifth of a second is a flicker, not
                // information.
                EmptyView()
            case .looking:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 16, height: 16)
                statusLine(localized("Looking for lyrics…"))
            case .off:
                statusGlyph("quote.bubble")
                statusLine(localized("Lyrics are off."))
                offerButton(localized("Show Lyrics"), action: turnOnLyrics)
            case .cannotLookUp(let sentence):
                statusGlyph("quote.bubble")
                statusLine(sentence)
            case .noneFound(let offersSearchOnline):
                statusGlyph("quote.bubble")
                statusLine(LyricsPageState.noneFoundSentence)
                HStack(spacing: 8) {
                    offerButton(localized("Import LRC…"), action: importLocalFile)
                    if offersSearchOnline {
                        offerButton(localized("Search Online"), action: turnOnOnlineLyrics)
                    }
                }
                if offersSearchOnline {
                    // The disclosure the old Look Up Online button carried:
                    // pressing it is the same informed choice as flipping the
                    // switch in Settings.
                    Text(localized("Sends the title, artist, album and length to LRCLIB."))
                        .islandFont(.caption, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .chooseLocal:
                statusLine(localized("Choose local lyrics…"))
                if case .some(.ambiguous(let candidates)) = localLookup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates) { candidate in
                            Button { selectLocalCandidate(candidate) } label: {
                                Text(Self.candidateLabel(candidate))
                                    .islandFont(.caption, weight: .regular)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(PanelButtonStyle())
                            .accessibilityLabel(Self.candidateLabel(candidate))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .unreadable(let line):
                statusGlyph("exclamationmark.bubble")
                statusLine(LyricsPageState.unreadableSentence(line: line))
                HStack(spacing: 8) {
                    offerButton(localized("Edit Lyrics…"), action: editBlankLyrics)
                    offerButton(localized("Import LRC…"), action: importLocalFile)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A little under the middle, where the board holds the glyph: the
        // header's tools above are never in its way and the footer's below are.
        .offset(y: 6)
        .transition(.opacity)
    }

    private func statusGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Theme.tertiary)
    }

    /// 12 pt medium, secondary: the one sentence a state says.
    private func statusLine(_ text: String) -> some View {
        Text(text)
            .islandFont(12, weight: .medium)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The pill the Music tab's "Open Spotify" wears: the one action on an
    /// otherwise empty page, 24 tall (the board's push button).
    private func offerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: 24))
        .padding(.top, 2)
    }

    /// A saved edit carries its source's tags word for word, so the source
    /// and its copy were two identical buttons (J-025). An edit ends with
    /// when it was saved — the time too, since two saves in one sitting are
    /// the commonest pair — and the row truncates in the middle so that end
    /// survives a long title.
    static func candidateLabel(_ candidate: LocalLyricsCandidate) -> String {
        let metadata = candidate.document.metadata
        let edited = candidate.editedAt.map {
            localized("Edited %@", $0.formatted(date: .abbreviated, time: .shortened))
        }
        return [metadata.title, metadata.artist, metadata.album, edited]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Where a click on a line sends the player, in player time, not lyric
    /// time: `now` reads the position through the lead and the listener's
    /// offset, so the jump subtracts them back out — or the line that lands
    /// as current is not the one that was clicked whenever the offset
    /// outweighs the line gap. The margin past the line's start is for where
    /// the player really lands. It was 0.02s, enough for floating-point
    /// rounding and nothing else, and a player that lands a few hundredths
    /// short — as they do — lit the line before the one clicked: forward, back,
    /// forward, filmed on 2026-09-21. `clickMargin` holds against that and
    /// still starts the audio ahead of the voice, since the lead already puts
    /// the jump before the line's timestamp. And a strongly negative offset
    /// near the end of the track must not clamp into the final second — that
    /// is a skip, not a seek.
    nonisolated static let clickMargin: TimeInterval = 0.12

    nonisolated static func clickTarget(lineAt: TimeInterval, lead: TimeInterval, duration: TimeInterval) -> TimeInterval {
        var target = max(0, lineAt - lead + clickMargin)
        if duration > 2 { target = min(target, duration - 1) }
        return target
    }

}

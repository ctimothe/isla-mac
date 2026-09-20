import SwiftUI

/// The full lyrics view: every line, scrolling with the voice.
///
/// This is the caption grown into a stage. The single `KaraokeText` under the
/// scrubber says *what is being sung now*; this says *where the song is* — the
/// sung lines above, the current line sweeping word by word, the next ones
/// waiting below, all riding the same position clock that keeps the caption
/// honest. Nothing else on the Mac has this, because it needs two things at
/// once: per-word timing data and a position accurate enough to sweep it.
///
/// The design follows the island's own grammar. The ground stays the panel's
/// black; the artwork is present only as ambience — blurred far past
/// recognition and dimmed, so it colours the room without competing with the
/// text. Lines materialize rather than appear: blur and scale settle as a line
/// takes focus. Reading position is fixed — the current line lives at the
/// stage's centre and the *text* moves through it, which is how every karaoke
/// surface since the bouncing ball has worked, because eyes stay still while
/// singing.
///
/// Every line is a button: tapping one seeks the song there. The header holds
/// the two honest utilities — a timing nudge for catalogue entries mastered
/// against a different cut, and "search again" for when the match itself is
/// wrong — and nothing else.
/// The Liquid Glass entrance: elements materialize by modulating blur, scale
/// and opacity together — light bending into focus — rather than fading flat.
struct MaterializeModifier: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.96 + 0.04 * progress)
            .opacity(progress)
    }
}

extension AnyTransition {
    // Main-actor because `AnyTransition` is not Sendable — and a transition is
    // only ever read from view code, which is main-actor anyway.
    @MainActor static let materialize = AnyTransition.modifier(
        active: MaterializeModifier(progress: 0),
        identity: MaterializeModifier(progress: 1)
    )
}

struct LyricsStage: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    var localLookup: LocalLyricsLookup? = nil
    var retry: () -> Void = {}
    var importLocalFile: () -> Void = {}
    var selectLocalCandidate: (LocalLyricsCandidate) -> Void = { _ in }
    var removeLocalBinding: () -> Void = {}
    var editLocalLyrics: (LocalLyricsCandidate) -> Void = { _ in }
    /// Folds the stage back into the ordinary pane.
    var dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False once the reader has scrolled away under their own hand: the stage
    /// then stays where it was put, and the song moving on no longer drags the
    /// page out from under the eye. The sync pill puts it back.
    @State private var following = true
    /// The line sitting at the reading centre, as the scroll view itself
    /// reports it. Both the way the page is driven when it follows the song and
    /// the way it is read when it does not.
    @State private var reading: TimeInterval?

    /// White, always — the same rule the lock card follows. A sung line
    /// coloured from the cover is unreadable the moment the cover is pale.
    private let accent: Color = .white

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

    var body: some View {
        ZStack {
            ambience
            VStack(spacing: 0) {
                header
                if case .ready = lyrics.availability,
                   case .synced(let lines) = lyrics.state,
                   !lines.isEmpty {
                    stage(lines: lines)
                } else {
                    unavailable
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Diagnostic readout, environment-gated like the open hook: says which
        // branch is live and why, in the corner, only when an agent launched
        // the binary with the variable set. Never present in a normal run.
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
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
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note("stage appeared: \(debugStateDescription)")
            }
        }
        // Verification hook, environment-gated like the open hook: replays the
        // row button's exact statement on the line after the current one, then
        // samples the position for the backward yank this hook exists to catch.
        // Never armed in a normal run.
        .task {
            guard ProcessInfo.processInfo.environment["DI_TEST_CLICK"] == "next" else { return }
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
        .onChange(of: debugStateDescription) { _, new in
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note(new)
            }
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

    // MARK: - Ambience

    /// The artwork as light, not as picture. Blurred to a wash, dimmed to
    /// stay a ground, and vignetted at the top and bottom so lines entering
    /// and leaving the stage dissolve into the room instead of hitting an
    /// edge.
    private var ambience: some View {
        ZStack {
            if let artwork = media.artwork {
                // Drawn through a `Color.clear` overlay, never as a sibling of
                // the gradient. A cover filled to the stage's width is as tall
                // as it is wide — 504 pt against a 162 pt body — and a ZStack
                // takes its tallest child however hard the result is clipped.
                // The stage then centred the sung line in 504 pt and drew it
                // below the island's edge: every line still visible was one the
                // song had passed, so clicking any of them seeked backwards.
                // An overlay cannot resize what it covers.
                Color.clear
                    .overlay {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60)
                            .opacity(0.35)
                    }
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.25),
                    .init(color: .black.opacity(0.45), location: 0.75),
                    .init(color: .black.opacity(0.85), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .animation(Theme.artworkAnimation, value: media.artwork)
        .clipped()
    }

    // MARK: - Stage

    /// Every row occupies the same fixed slot, which is what makes the motion
    /// exact: the song's position maps to a row by plain arithmetic, and the
    /// `ScrollView` below is driven to that row through `scrollPosition` as
    /// one value — the clock moves the page, and a hand may move it too.
    static let slotHeight: CGFloat = 40
    static let slotSpacing: CGFloat = 8

    /// Padding above the first line and below the last, so both ends can reach
    /// the reading centre. Half the viewport less half a slot; never negative,
    /// because a viewport shorter than one line would otherwise pull the whole
    /// column upward by the difference.
    static func centeringAir(viewport: CGFloat) -> CGFloat {
        max(0, viewport / 2 - slotHeight / 2)
    }

    private func stage(lines: [LyricsStore.Line]) -> some View {
        let currentIndex = LyricSweep.index(in: lines, at: now)
        // Before the first line — an intro — the first line is the anchor:
        // waiting at the reading centre, dimmed, taking the sweep the moment
        // the voice arrives. Anchoring on nothing left the stage vacant.
        let anchor = currentIndex ?? 0
        return GeometryReader { geo in
                // Half a viewport of air above the first line and below the
                // last, so either end can still reach the reading centre
                // instead of stopping short against the scroll bounds.
                let air = Self.centeringAir(viewport: geo.size.height)
                let strayed = Self.linesStrayed(reading: reading, from: anchor, in: lines)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Self.slotSpacing) {
                        ForEach(Array(lines.enumerated()), id: \.element.at) { index, line in
                            row(line: line, index: index, current: currentIndex, lines: lines)
                                .frame(height: Self.slotHeight, alignment: .leading)
                                .id(line.at)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, air)
                }
                .scrollPosition(id: $reading, anchor: .center)
                    // Lines dissolve at the viewport's edges instead of being
                    // guillotined mid-glyph by the clip.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.18),
                                .init(color: .black, location: 0.78),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // The song moving on carries the page with it — but only
                    // while nobody is reading ahead by hand.
                .onChange(of: anchor) { from, to in
                    if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                        DebugTrail.note(String(
                            format: "STAGE anchor %d->%d current=%d now=%.2f lines=%d viewport=%.0f follow=%d strayed=%d",
                            from, to, currentIndex ?? -1, now,
                            lines.count, geo.size.height, following ? 1 : 0, strayed))
                    }
                    guard following else { return }
                    center(on: lines[to].at)
                }
                .onChange(of: following) { _, resumed in
                    guard resumed else { return }
                    center(on: lines[anchor].at)
                }
                .onAppear { reading = lines[anchor].at }
                    // A scroll wheel or two fingers on the trackpad is the one
                    // unambiguous statement of "I am reading, not watching":
                    // taken straight from the event stream rather than inferred
                    // from where the scroll view ended up, which cannot tell a
                    // hand from our own animation.
                .onScrollWheel {
                    guard following else { return }
                    following = false
                    if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                        DebugTrail.note("STAGE reader took over")
                    }
                }
                // Only once the sung line has actually left the stage. A pill
                // that appears the instant the page moves is an alarm about
                // nothing: a line or two of drift still has the voice on
                // screen, and the way back is to keep reading.
                .overlay(alignment: .bottomTrailing) {
                    if !following, strayed >= Self.strayedEnoughToOfferSync {
                        syncPill
                            .padding(.trailing, 2)
                            .padding(.bottom, 4)
                            .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
                    }
                }
                .animation(reduceMotion ? nil : Theme.contentAnimation, value: following)
                .animation(reduceMotion ? nil : Theme.contentAnimation, value: strayed)
        }
        .padding(.horizontal, 22)
    }

    /// Puts the sung line back at the reading centre.
    ///
    /// On `Theme.lyricScroll`, not on the generic content ease this used to
    /// borrow. `Theme.contentAnimation` is 0.16s — it is the curve for a badge
    /// appearing — and one page step here is a whole slot, 48pt, moved because
    /// the song moved. At 0.16s the page beat the thing it exists to carry:
    /// `KaraokeText` sweeps a line over `.linear(duration: 0.25)`, so the new
    /// line was already parked at the reading centre with its sweep still
    /// crossing it. The page has to be the slower of the two, and it is the one
    /// animation in this app allowed a little overshoot — see the comment on
    /// `Theme.lyricScroll` for why the momentum rule permits exactly this one.
    ///
    /// The Reduce Motion branch is now inside `Theme.lyricScroll(reduceMotion:)`
    /// rather than being a bare assignment here. It still refuses the spring —
    /// what it no longer does is snap the page between lines with no transition
    /// at all, which is the same answer `Theme.open(reduceMotion:)` gives.
    private func center(on id: TimeInterval) {
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
    /// stage shows about three lines, so one line either side of the sung one
    /// is still in view and needs no rescuing.
    static let strayedEnoughToOfferSync = 2

    /// Lines between what is being read and what is being sung.
    static func linesStrayed(reading: TimeInterval?, from anchor: Int, in lines: [LyricsStore.Line]) -> Int {
        guard let reading, let index = LyricSweep.index(in: lines, at: reading) else { return 0 }
        return abs(index - anchor)
    }

    /// The way back to the song after reading ahead — Spotify's affordance, and
    /// the only honest one: a page that yanks itself back on a timer takes the
    /// line away mid-sentence.
    private var syncPill: some View {
        Button {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note("SYNC tapped")
            }
            following = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "music.note")
                    .islandFont(.caption, weight: .bold)
                Text(localized("Sync"))
                    .islandFont(.caption, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // The same glass as every other floating surface here — it sits
            // inside an opaque panel, so there is nothing behind it to sample.
            .glassSurface(cornerRadius: 999, elevation: .pill, samplesBackdrop: false)
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel(localized("Back to the current line"))
        .help(localized("Back to the current line"))
    }

    private func row(line: LyricsStore.Line, index: Int, current: Int?, lines: [LyricsStore.Line]) -> some View {
        let isCurrent = index == current
        // How far from the voice this line stands, for the depth falloff.
        let distance = current.map { abs(index - $0) } ?? 2
        return LyricRow(
            line: line,
            isCurrent: isCurrent,
            distance: distance,
            at: now,
            end: LyricSweep.end(of: index, in: lines),
            // The stage reads at arm's length and lets a long line wrap; the
            // card holds one line at a glance. Wrapping is the only thing
            // either surface still decides for itself — both read at the title
            // size, which is where the two had already met in one tracking band.
            fontSize: Theme.TypeRole.title.size,
            weight: .bold,
            lineLimit: 2,
            accent: accent,
            reduceMotion: reduceMotion,
            wordTimingEnabled: wordTimingEnabled,
            seek: {
                if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
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
            allText: Self.plainText(lines)
        )
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: isCurrent)
        .id(line.at)
        .accessibilityHint(localized("Jumps the song to this line"))
    }

    /// The sung prefix in the accent, the rest dimmed-bright, as one wrapping
    /// Text — so a two-row line fills in reading order.

    /// The nudge corrects the loaded track's own layer, so without synced
    /// words there is nothing to correct: persisting needs `.synced`, and a
    /// nudge made without it would sit in the overlay until the next cache
    /// hit restores the file's 0 over it, silently eating the correction.
    private var canNudgeTrack: Bool {
        if case .ready = lyrics.availability, case .synced = lyrics.state { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .islandFont(.caption, weight: .semibold)
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .help(localized("Back to Player"))
            .accessibilityLabel(localized("Back to Player"))

            Spacer(minLength: 0)

            // The per-track timing nudge. Shown as the correction it is; zero
            // reads as nothing rather than as "+0.00s". This moves only this
            // track's layer — a remaster fixed here never shifts any other
            // song — and holding the readout clears it back to 0.
            if canNudgeTrack {
                HStack(spacing: 4) {
                Button { lyrics.nudgeTrackOffset(by: -0.25) } label: {
                    Image(systemName: "minus")
                        // Fitted to the 22pt well, not set as type: a caption
                        // glyph would crowd a button this small.
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(NotchButtonStyle(size: 22))
                .disabled(!canNudgeTrack)
                .accessibilityLabel(localized("Lyrics Earlier"))
                if abs(lyrics.trackOffset) > 0.01 {
                    Text(localized("%+.2fs", lyrics.trackOffset))
                        .font(Theme.TypeRole.caption.font().monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .frame(minWidth: 40)
                        // The only reset, and deliberately a held one: a tap
                        // target this small, beside two steppers, would eat
                        // nudges meant for its neighbours.
                        .onLongPressGesture { lyrics.clearTrackOffset() }
                        .help(localized("Reset lyric timing"))
                        .accessibilityHint(localized("Reset lyric timing"))
                }
                Button { lyrics.nudgeTrackOffset(by: 0.25) } label: {
                    Image(systemName: "plus")
                        // Same fitted glyph as the minus beside it.
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(NotchButtonStyle(size: 22))
                .disabled(!canNudgeTrack)
                .accessibilityLabel(localized("Lyrics Later"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localized("Lyric Timing"))
            }

            Button(action: chooseLocalLRC) {
                Image(systemName: "doc.badge.plus")
                    .islandFont(.caption, weight: .semibold)
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .accessibilityLabel(localized("Import Local LRC"))
            .help(localized("Import Local LRC"))

            if case .some(.ready(let candidate)) = localLookup {
                Button { editLocalLyrics(candidate) } label: {
                    Image(systemName: "pencil")
                        .islandFont(.caption, weight: .semibold)
                }
                .buttonStyle(NotchButtonStyle(size: 24))
                .accessibilityLabel(localized("Edit Lyrics"))
                .help(localized("Edit Lyrics"))
            }

            if lyrics.hasLocalOverride {
                Button(action: removeLocalBinding) {
                    Image(systemName: "trash")
                        .islandFont(.caption, weight: .semibold)
                }
                .buttonStyle(NotchButtonStyle(size: 24))
                .accessibilityLabel(localized("Remove Local Binding"))
                .help(localized("Remove Local Binding"))
            }

            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
                    .islandFont(.caption, weight: .semibold)
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .disabled(!LyricsPresentation.canRetry(lyrics.availability))
            .accessibilityLabel(localized("Retry"))
            .help(localized("Retry"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func chooseLocalLRC() { importLocalFile() }

    // MARK: - Empty

    private var unavailable: some View {
        VStack(spacing: 8) {
            if case .findingLocalLyrics = lyrics.availability {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "text.quote")
                    .islandFont(.display, weight: .light)
                    .foregroundStyle(Theme.tertiary)
                Text(LyricsPresentation.compactCaption(
                    for: lyrics.availability, currentLine: nil, localLookup: localLookup
                ))
                    .islandFont(.body)
                    .foregroundStyle(Theme.secondary)
            }
            if case .some(.ambiguous(let candidates)) = localLookup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { candidate in
                        Button { selectLocalCandidate(candidate) } label: {
                            Text(candidateLabel(candidate))
                                .islandFont(.caption, weight: .regular)
                                .lineLimit(1)
                        }
                        .buttonStyle(PanelButtonStyle())
                        .accessibilityLabel(candidateLabel(candidate))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateLabel(_ candidate: LocalLyricsCandidate) -> String {
        let metadata = candidate.document.metadata
        return [metadata.title, metadata.artist, metadata.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Index of the line being sung at `at`, by the same binary search the
    /// caption uses.
    /// Where a click on a line sends the player, in player time, not lyric
    /// time: `now` reads the position through the lead and the listener's
    /// offset, so the jump subtracts them back out — or the line that lands
    /// as current is not the one that was clicked whenever the offset
    /// outweighs the line gap. The 0.02 nudge is for a paused player: seeking
    /// to exactly `line.at - lead` leaves `now` one floating-point rounding
    /// away from the line's own timestamp, and with no ticker running to
    /// cross it the previous line could stay highlighted. And a strongly
    /// negative offset near the end of the track must not clamp into the
    /// final second — that is a skip, not a seek.
    static func clickTarget(lineAt: TimeInterval, lead: TimeInterval, duration: TimeInterval) -> TimeInterval {
        var target = max(0, lineAt - lead + 0.02)
        if duration > 2 { target = min(target, duration - 1) }
        return target
    }

}

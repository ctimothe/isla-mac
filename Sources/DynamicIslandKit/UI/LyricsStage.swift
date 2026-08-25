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

    /// The one lead, shared with the caption and the lock card.
    private var lead: TimeInterval {
        LyricSweep.lead(precisionSync: media.precisionSync, userOffset: lyrics.userOffset)
    }

    private var now: TimeInterval { media.position + lead }

    var body: some View {
        ZStack {
            ambience
            if case .synced(let lines) = lyrics.state, !lines.isEmpty {
                stage(lines: lines)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Diagnostic readout, environment-gated like the open hook: says which
        // branch is live and why, in the corner, only when an agent launched
        // the binary with the variable set. Never present in a normal run.
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                Text(debugStateDescription)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
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
                          let current = Self.index(in: lines, at: now),
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
    /// exact: the whole column's offset is plain arithmetic on the current
    /// index, animated as one value. No scroll view — the song is the only
    /// thing that moves this surface, and a scroll view's own machinery
    /// (which additionally refuses to render at all inside this panel's
    /// hosting configuration) had nothing to offer but ways to disagree
    /// with the clock.
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
        let currentIndex = Self.index(in: lines, at: now)
        // Before the first line — an intro — the first line is the anchor:
        // waiting at the reading centre, dimmed, taking the sweep the moment
        // the voice arrives. Anchoring on nothing left the stage vacant.
        let anchor = currentIndex ?? 0
        return VStack(spacing: 0) {
            header
            GeometryReader { geo in
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
    }

    /// Puts the sung line back at the reading centre.
    private func center(on id: TimeInterval) {
        guard !reduceMotion else {
            reading = id
            return
        }
        withAnimation(Theme.contentAnimation) { reading = id }
    }

    /// How far the page may drift before the way back is worth offering: the
    /// stage shows about three lines, so one line either side of the sung one
    /// is still in view and needs no rescuing.
    static let strayedEnoughToOfferSync = 2

    /// Lines between what is being read and what is being sung.
    static func linesStrayed(reading: TimeInterval?, from anchor: Int, in lines: [LyricsStore.Line]) -> Int {
        guard let reading, let index = index(in: lines, at: reading) else { return 0 }
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
                    .font(.system(size: 9, weight: .bold))
                Text(localized("Sync"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // The same glass as every other floating surface here — it sits
            // inside an opaque panel, so there is nothing behind it to sample.
            .glassSurface(cornerRadius: 999, elevation: .pill, samplesBackdrop: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("Back to the current line"))
        .help(localized("Back to the current line"))
    }

    @ViewBuilder
    private func row(line: LyricsStore.Line, index: Int, current: Int?, lines: [LyricsStore.Line]) -> some View {
        let isCurrent = index == current
        // How far from the voice this line stands, for the depth falloff.
        let distance = current.map { abs(index - $0) } ?? 2
        Button {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note(String(
                    format: "ROW CLICK index=%d at=%.2f current=%d pos=%.2f",
                    index, line.at, current ?? -1, media.position
                ))
            }
            media.seek(to: Self.clickTarget(lineAt: line.at, lead: lead, duration: media.duration))
            // Choosing a line is choosing the song's place in it: the page
            // follows again from there rather than stranding the reader one
            // tap away from a stage that no longer moves.
            following = true
        } label: {
            Group {
                if line.isCredit {
                    // Never swept, never bold: a credit is on screen because
                    // the song has not started, and dressing it as the current
                    // lyric would claim somebody is singing "Produced by".
                    Text(line.text)
                        .font(.system(size: 12, weight: .medium))
                        .italic()
                        .foregroundStyle(.white.opacity(isCurrent ? 0.68 : 0.34))
                        .lineLimit(2)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else if isCurrent {
                    let end = index + 1 < lines.count ? lines[index + 1].at : line.at + 6
                    // The same renderer the caption and the lock card use. It
                    // clips each laid-out row on its own, so a line wrapped to
                    // two rows fills top row first, in reading order — which a
                    // single rectangle mask could never do — and it interpolates
                    // between position ticks instead of stepping with them.
                    KaraokeText(
                        text: line.text,
                        fraction: LyricSweep.fraction(line: line, at: now, end: end),
                        reduceMotion: reduceMotion,
                        accent: accent,
                        font: .system(size: 15, weight: .bold),
                        // Brighter than any neighbour even before the sweep
                        // arrives — the line being sung must never be the
                        // darkest thing on stage.
                        base: .white.opacity(0.62),
                        lineLimit: 2
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    // Depth through opacity alone. The first cut blurred and
                    // fractionally scaled these — which on 12pt text is not
                    // depth, it is smeared type: subpixel scaling rasterizes
                    // every glyph soft, and a two-point blur at reading size
                    // just looks like a rendering bug.
                    Text(line.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(distance == 1 ? 0.42 : 0.22)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: isCurrent)
        .id(line.at)
        .accessibilityLabel(line.text)
        .accessibilityHint(localized("Jumps the song to this line"))
    }

    /// The sung prefix in the accent, the rest dimmed-bright, as one wrapping
    /// Text — so a two-row line fills in reading order.
    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .accessibilityLabel(localized("Back to Player"))

            Spacer(minLength: 0)

            // The timing nudge. Shown as the correction it is; zero reads as
            // nothing rather than as "+0.00s".
            HStack(spacing: 4) {
                Button { lyrics.userOffset -= 0.25 } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(NotchButtonStyle(size: 20))
                .accessibilityLabel(localized("Lyrics Earlier"))
                if abs(lyrics.userOffset) > 0.01 {
                    Text(String(format: "%+.2fs", lyrics.userOffset))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .frame(minWidth: 40)
                }
                Button { lyrics.userOffset += 0.25 } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(NotchButtonStyle(size: 20))
                .accessibilityLabel(localized("Lyrics Later"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localized("Lyric Timing"))

            // The bad-match escape hatch.
            Button {
                guard let track = media.track else { return }
                lyrics.research(
                    title: track.title, artist: track.artist,
                    album: track.album, duration: media.duration,
                    spotifyID: media.spotifyTrackID
                )
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .accessibilityLabel(localized("Search Lyrics Again"))
            .help(localized("Wrong lyrics? Search again"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: - Empty

    /// Loading, or genuinely nothing. Either way the stage says so instead of
    /// standing empty.
    private var unavailable: some View {
        VStack(spacing: 8) {
            if case .loading = lyrics.state {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "text.quote")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                Text(localized("No lyrics for this track"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .accessibilityLabel(localized("Back to Player"))
            .padding(.leading, 14)
            .padding(.top, 10)
        }
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

    static func index(in lines: [LyricsStore.Line], at: TimeInterval) -> Int? {
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].at <= at { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found >= 0 ? found : nil
    }
}

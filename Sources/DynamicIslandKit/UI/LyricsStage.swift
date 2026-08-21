import SwiftUI

/// The full lyrics view: every line, scrolling with the voice.
///
/// This is the caption grown into a stage. The single `KaraokeLine` under the
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
    @State private var palette: ArtworkPalette?

    private var accent: Color {
        guard let palette, palette.isVivid else { return .white }
        return Color(nsColor: palette.dominant)
    }

    /// Same leads as the caption, plus the listener's own correction.
    private var now: TimeInterval {
        media.position
            + (media.precisionSync ? 0.25 : 0.45)
            + lyrics.userOffset
    }

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
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                Text(debugStateDescription)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.yellow)
                    .padding(6)
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note("stage appeared: \(debugStateDescription)")
            }
        }
        .onChange(of: debugStateDescription) { _, new in
            if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
                DebugTrail.note(new)
            }
        }
        .task(id: media.artwork) {
            guard let artwork = media.artwork else {
                palette = nil
                return
            }
            palette = await Task.detached(priority: .userInitiated) {
                ArtworkPalette.extract(from: artwork)
            }.value
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
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.35)
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
    private static let slotHeight: CGFloat = 40
    private static let slotSpacing: CGFloat = 8

    private func stage(lines: [LyricsStore.Line]) -> some View {
        let currentIndex = Self.index(in: lines, at: now)
        // Before the first line — an intro — the first line is the anchor:
        // waiting at the reading centre, dimmed, taking the sweep the moment
        // the voice arrives. Anchoring on nothing left the stage vacant.
        let anchor = currentIndex ?? 0
        return VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let pitch = Self.slotHeight + Self.slotSpacing
                VStack(alignment: .leading, spacing: Self.slotSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.element.at) { index, line in
                        row(line: line, index: index, current: currentIndex, lines: lines)
                            .frame(height: Self.slotHeight, alignment: .leading)
                    }
                }
                .offset(y: geo.size.height / 2 - (CGFloat(anchor) * pitch + Self.slotHeight / 2))
                .animation(reduceMotion ? nil : Theme.contentAnimation, value: anchor)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
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
            }
            .padding(.horizontal, 22)
        }
    }

    @ViewBuilder
    private func row(line: LyricsStore.Line, index: Int, current: Int?, lines: [LyricsStore.Line]) -> some View {
        let isCurrent = index == current
        // How far from the voice this line stands, for the depth falloff.
        let distance = current.map { abs(index - $0) } ?? 2
        Button {
            // Slightly before the line, so its first word is sung, not missed.
            media.seek(to: max(0, line.at - 0.15))
        } label: {
            Group {
                if isCurrent {
                    let end = index + 1 < lines.count ? lines[index + 1].at : line.at + 6
                    // Colored by character, not swept by a mask. A rectangle
                    // mask is geometry: on a line wrapped to two rows it lit
                    // the left half of *both* rows at once — the reading edge
                    // in the wrong place on every long lyric. Splitting the
                    // string itself at the sung boundary lets the highlight
                    // flow with the wrap, top row first, exactly as read.
                    wrappedKaraoke(
                        text: line.text,
                        fraction: reduceMotion ? 1 : LockScreenCard.sweepFraction(line: line, at: now, end: end)
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
    private func wrappedKaraoke(text: String, fraction: Double) -> some View {
        let characters = Array(text)
        let boundary = min(Int((Double(characters.count) * fraction).rounded()), characters.count)
        var sung = AttributedString(String(characters[0..<boundary]))
        sung.foregroundColor = accent == .white ? Color.white : accent
        var rest = AttributedString(String(characters[boundary...]))
        // Brighter than any neighbour even before the sweep arrives — the
        // line being sung must never be the darkest thing on stage.
        rest.foregroundColor = .white.opacity(0.62)
        return Text(sung + rest)
            .font(.system(size: 15, weight: .bold))
            .lineLimit(2)
            .truncationMode(.tail)
    }

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
    private static func index(in lines: [LyricsStore.Line], at: TimeInterval) -> Int? {
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].at <= at { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found >= 0 ? found : nil
    }
}

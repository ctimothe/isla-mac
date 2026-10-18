import AppKit
import Combine
import CoreAudio
import SwiftUI

/// The player (spec §19.6, board `R2-Music-Open`): what a click on the island
/// opens while a song is the live activity.
///
/// The cover, the title and the artist, the equalizer the island's own bars
/// travel to, the times either side of the progress, and one row of five
/// controls — Favourite, Previous, Play / Pause, Next, Output — every one a
/// 42 pt target. Shuffle and Repeat left for the stage's More menu, and the
/// lyric column and the tall page went with the tabs; the stage is a surface
/// of its own (`LyricsStageSurface`), opened from the cover and the sung line.
///
/// Every frame comes from `PlayerLayout`, in the content's coordinates, so a
/// test holds the board's numbers without rendering anything.
struct MediaPane: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    /// Opens the stage: the cover of a song with lyrics, and the sung line.
    var openStage: () -> Void = {}
    /// Brings the song's player forward: the cover of a song with no lyrics.
    var bringPlayerForward: () -> Void = {}
    /// Settings, scrolled to the Music section, for the empty player's one
    /// remedy when Music Only is what keeps a playing source off the island.
    var openMusicOnlySetting: () -> Void = {}
    /// The namespace the cover and the equalizer travel in, when this pane is
    /// inside the panel.
    ///
    /// Optional because the pane is also rendered on its own — by the layout
    /// tests, with no pill above it and nothing to travel from. `nil` means
    /// "draw the cover where it lands and nothing else".
    var morph: Namespace.ID?
    /// The machine's audio state, for the Output button and its menu. The
    /// default reads nothing and installs nothing: a pane built anywhere but the
    /// panel — a test, a render — must not reach the owner's output devices, even
    /// to read them. The panel hands in `NotchViewModel.playerAudio`.
    @ObservedObject var audio: AudioWatch = MediaPane.quietAudio()
    /// The Spotify account, for the Favourite star on a Spotify song. Nil
    /// outside the panel: the live account's first read is the owner's own
    /// keychain, which nothing but the panel may touch.
    var spotify: SpotifyAccount? = nil
    /// The cover's tint, for the equalizer's bars.
    var coverTint: NSColor = CoverTint.fallback.nsColor
    /// Whether this is the page on screen, or Music drawn beside it for a
    /// swipe's length (§19.16). Only the page on screen asks the player for
    /// its modes and watches the outputs: a partial swipe from the Shelf
    /// toward Music and back scripted Spotify and started CoreAudio
    /// listeners for nothing (R8b review F8).
    var isLive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = SystemAppearance.shared

    /// Output Button, and Lyric Band: Settings › Music (spec §14). Read
    /// through `@AppStorage` so the switch in Settings redraws the player while
    /// it is on screen. Absent means the spec's default — **on** for both, and
    /// the Output button is the owner-waived exception to the default-off rule
    /// for system-wide settings (`NotchViewModel.volumeAndOutputEnabled`; the
    /// stored key keeps its old name, "Volume and Output", so the owner's
    /// choice survives the 2026-10-16 relabel).
    @AppStorage(NotchViewModel.volumeAndOutputKey) private var outputButtonOn = true
    @AppStorage(NotchViewModel.lyricBandKey) private var lyricBandOn = true

    /// A watch that reads an empty machine and installs nothing.
    static func quietAudio() -> AudioWatch {
        AudioWatch(read: { ([], nil, nil) }, readMuted: { false }, installListeners: {}, removeListeners: {})
    }

    @State private var scrubHover = false
    /// Set once the pointer has rested on the bar for a moment.
    ///
    /// The elapsed label reads the time under the pointer while it is on the
    /// bar. Filmed on 2026-09-21: a pointer only crossing the bar on its way to
    /// the skip button flashed 1:42, 1:55, 2:14 over the time playing, and it
    /// read as the clock jumping about. A crossing is too quick to arm it.
    @State private var previewArmed = false
    @State private var previewArmTask: Task<Void, Never>?
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?
    /// Cursor x inside the bar while hovering, so the elapsed label can read
    /// the time under the pointer.
    @State private var hoverX: CGFloat?
    /// Set once the current track has waited long enough for artwork that it
    /// is evidently not coming. Some sources never publish a cover, and a
    /// shimmer that promises one forever reads as stuck, not loading.
    @State private var artworkWaitExpired = false
    /// Observed so the empty player's "Open …" buttons follow an app being
    /// installed or removed (`AppIcons.refresh`).
    @ObservedObject var icons: AppIcons = .shared

    private var layout: PlayerLayout { PlayerLayout(hasOutputButton: outputButtonOn) }

    /// Where the pointer (or the finger mid-drag) sits along the bar, 0...1.
    /// Nil when neither is on it, which is when the label goes back to saying
    /// where the song actually is.
    private var previewFraction: Double? {
        if let scrubbing { return scrubbing }
        guard scrubHover, previewArmed, let hoverX else { return nil }
        return ScrubPreview.fraction(x: hoverX, width: layout.progress.width, duration: media.duration)
    }

    var body: some View {
        if let track = media.track {
            player(for: track)
                .onAppear { if isLive { startWatching() } }
                .onChange(of: isLive) { _, live in if live { startWatching() } }
                // The watch follows the machine only while there is a button to
                // show it in, and only while the pane is on screen: it reads, and
                // installs CoreAudio listeners, and writes nothing.
                .onChange(of: outputButtonOn) { _, on in
                    if on { audio.start() } else { audio.stop() }
                }
                .onDisappear { audio.stop() }
        } else {
            emptyState
        }
    }

    private func startWatching() {
        media.refreshPlaybackModes()
        if outputButtonOn { audio.start() }
    }

    // MARK: - The player (spec §19.6)

    private func player(for track: MediaController.Track) -> some View {
        let layout = layout
        let band = sungLine
        return ZStack(alignment: .topLeading) {
            // The content's own size, so the children are placed from its
            // top-left corner whatever they measure.
            Color.clear

            coverButton(for: track)
                .placedAt(layout.cover)

            titleRow(for: track, withArtist: band.isOn)
                .placedAt(Self.textBox(
                    x: layout.textLeading, baseline: layout.titleBaseline, width: layout.titleWidth,
                    size: PlayerLayout.titleSize, weight: .medium
                ))

            subtitle(for: track, band: band)
                .placedAt(Self.textBox(
                    x: layout.textLeading, baseline: layout.subtitleBaseline, width: layout.subtitleWidth,
                    size: PlayerLayout.subtitleSize, weight: .semibold
                ))

            CompactEqualizer(
                isAnimating: media.isPlaying,
                colors: CompactEqualizerMotion.colors(
                    isPlaying: media.isPlaying, tint: coverTint,
                    increaseContrast: appearance.increaseContrast
                )
            )
            // The far end of the equalizer's travel: the same bars that were in
            // the island's right wing a moment ago, not a second set.
            .morph(NotchContentView.MorphID.equalizer, in: morph)
            .placedAt(layout.equalizer, alignment: .center)
            .accessibilityHidden(true)

            progressRow
            controls
        }
        // Title and artist arrive together, so the column crossfades as one
        // unit when the track changes.
        .animation(Theme.artworkAnimation, value: track.key)
        // The band trades the artist line for the sung one and moves nothing,
        // so it fades under Reduce Motion too: a fade is not motion.
        .animation(Theme.contentAnimation, value: band.isOn)
    }

    /// The box a line of text is laid in so that its baseline lands at
    /// `baseline`: SF's ascender above it and its descender below, as
    /// `NSFont` measures them at that size. A single-line `Text` is laid out
    /// exactly that tall, so placing the box places the baseline.
    static func textBox(
        x: CGFloat, baseline: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight,
        rounded: Bool = false
    ) -> CGRect {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let ascent = ceil(font.ascender)
        let descent = ceil(-font.descender)
        return CGRect(x: x, y: baseline - ascent, width: width, height: ascent + descent)
    }

    // MARK: Cover

    /// The cover is a button (§19.6): it opens the stage when the song has
    /// lyrics, and otherwise brings the player forward.
    private func coverButton(for track: MediaController.Track) -> some View {
        let opensStage = Self.coverOpensStage(availability: lyrics.availability)
        return Button {
            if opensStage { openStage() } else { bringPlayerForward() }
        } label: {
            artwork(for: track)
        }
        .buttonStyle(PanelButtonStyle())
        .help(opensStage ? localized("Lyrics") : (media.sourceName ?? ""))
        .accessibilityLabel(opensStage ? localized("Lyrics") : localized("Cover"))
        .accessibilityHint(opensStage ? localized("Opens the full lyrics") : "")
    }

    /// Whether the cover opens the stage: only when there are lyrics to show
    /// in it. A stage opened on "No lyrics found." is a dead end one click
    /// deep; the player is one click away instead.
    static func coverOpensStage(availability: LyricsAvailability) -> Bool {
        if case .ready = availability { return true }
        return false
    }

    /// The far end of the cover's travel from the island.
    ///
    /// `Color.clear` is the base for a reason: the cover has to *accept*
    /// whatever size it is offered — the morph offers it the island's size on
    /// the way in — and a view that states its own size is one the effect
    /// cannot resize. The picture rides above it in an overlay, free to
    /// overflow and be clipped.
    private func artwork(for track: MediaController.Track) -> some View {
        let radius = PlayerLayout.coverRadius
        return Color.clear
            .overlay {
                if let image = media.artwork {
                    // No opacity transition: a travelling object that fades
                    // while it travels is the crossfade the morph replaced.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if artworkWaitExpired {
                    // The wait is over and the cover is not coming for this
                    // track (spec §4.7): the well, never a stretched app icon.
                    MissingCoverWell(cornerRadius: radius, noteSize: 22)
                        .transition(.opacity)
                } else {
                    SkeletonBox(cornerRadius: radius)
                }
            }
            .task(id: track.key) {
                artworkWaitExpired = false
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                artworkWaitExpired = true
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Paused, the cover is 0.8 of itself (spec §4.2). A colour multiply,
            // not `.brightness`, which is additive and lifts the black of a dark
            // cover towards grey.
            .colorMultiply(media.isPlaying ? .white : Color(white: Theme.playerPausedCoverBrightness))
            .animation(Theme.contentAnimation, value: media.isPlaying)
            // The same shape again for the pointer: `.fill` on a cover that is
            // not square overflows, and the overflow must not take clicks meant
            // for the title beside it (#22).
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.coverEdge, lineWidth: 0.5)
            )
            .morph(NotchContentView.MorphID.artwork, in: morph)
            .animation(Theme.artworkAnimation, value: media.artwork)
    }

    // MARK: Title and the sung line

    /// "Title", or — while the sung line has the subtitle — "Title – Artist",
    /// the artist at white 0.50 (§19.6). A line longer than its room scrolls
    /// to show the rest (`MarqueeLine`); where it may not move, the artist is
    /// the first to give way, as it always was.
    private func titleRow(for track: MediaController.Track, withArtist: Bool) -> some View {
        let artist = withArtist && !track.artist.isEmpty ? track.artist : nil
        let line = Self.titleLine(title: track.title, artist: artist)
        return MarqueeLine(room: layout.titleWidth, isActive: isLive && !reduceMotion, text: line) {
            HStack(spacing: 0) {
                Text(track.title)
                    .foregroundStyle(.white.opacity(Theme.playerTitleOpacity))
                    .layoutPriority(1)
                if let artist {
                    Text(Self.artistSeparator + artist)
                        .foregroundStyle(.white.opacity(Theme.playerArtistOpacity))
                }
            }
        }
        .font(.system(size: PlayerLayout.titleSize, weight: .medium))
        .tracking(Theme.tracking(forSize: PlayerLayout.titleSize))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }

    /// Between the title and the artist: a dash, which reads as "by" at a
    /// glance where the middle dot read as a list (owner, 2026-10-18). An en
    /// dash, the separator's own glyph, which reads as the plain hyphen asked
    /// for without the hyphen's join-a-word look.
    static let artistSeparator = " – "

    /// The title row's words, which are also its tooltip and its label.
    static func titleLine(title: String, artist: String?) -> String {
        guard let artist, !artist.isEmpty else { return title }
        return title + artistSeparator + artist
    }

    /// What the subtitle carries while the song has synced lyrics and Lyric
    /// Band is on: the line being sung, and between lines, before the first
    /// and after the last, the line the voice reaches next, unswept — the
    /// island caption's rule (`LyricMoment.centre`). The artist only when the
    /// band is off.
    ///
    /// Between lines it used to be the artist, which the title row already
    /// shows while the band is on: every pause of a second or two read the
    /// artist twice, and the line then snapped in when the voice came back
    /// (owner, 2026-10-18). Holding the coming line, its row is the same one
    /// when the voice reaches it, so a pause turns nothing and the sweep
    /// simply starts.
    struct SungLine {
        /// Whether the band is on for this song at all, which is what turns
        /// the title into "Title · Artist".
        var isOn: Bool
        var lines: [LyricsStore.Line] = []
        var resolution: LyricResolution?

        /// The row the subtitle shows: the sung line, or the one coming.
        var index: Int? { resolution.map { $0.current ?? $0.centre } }
        /// Whether the voice is in that row, which is what sweeps it.
        var isSung: Bool { resolution?.current != nil }
        /// How far the sweep has lit that row: none of a line still coming.
        /// The view draws this, not the resolution's own, so what the tests
        /// pin is what is drawn (review 5, S4).
        var fraction: Double { isSung ? resolution?.fraction ?? 0 : 0 }
    }

    private var sungLine: SungLine {
        guard Self.drawsLyricBand(setting: lyricBandOn, availability: lyrics.availability, state: lyrics.state),
              case .synced(let lines) = lyrics.state else { return SungLine(isOn: false) }
        let resolution = Self.captionResolution(lines: lines, inputs: LyricInputs(
            position: media.position,
            precisionSync: media.precisionSync,
            userOffset: lyrics.userOffset,
            trackOffset: lyrics.trackOffset,
            wordTiming: wordTimingEnabled
        ), readAhead: lyrics.readAhead)
        return SungLine(isOn: true, lines: lines, resolution: resolution)
    }

    private var wordTimingEnabled: Bool {
        LyricsPresentation.usesWordTiming(
            lyrics.timingGranularity, precisionMeasured: media.precisionSync,
            wordKaraokeEnabled: lyrics.wordKaraokeEnabled
        )
    }

    @ViewBuilder
    private func subtitle(for track: MediaController.Track, band: SungLine) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            if band.isOn, let index = band.index, let resolution = band.resolution {
                let line = band.lines[index]
                Button(action: openStage) {
                    KaraokeText(
                        text: Self.bandText(of: line),
                        fraction: band.fraction,
                        clock: resolution.current.flatMap { current in
                            LyricSweep.liveFraction(
                                line: line, end: LyricSweep.end(of: current, in: band.lines),
                                wordTiming: wordTimingEnabled,
                                clock: LyricSweep.frameClock(media: media, lead: LyricSweep.lead(
                                    precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                                    trackOffset: lyrics.trackOffset
                                ))
                            )
                        },
                        reduceMotion: reduceMotion,
                        accent: .white.opacity(Theme.playerSungOpacity),
                        font: .system(size: PlayerLayout.subtitleSize, weight: .semibold),
                        tracking: Theme.tracking(forSize: PlayerLayout.subtitleSize),
                        base: .white.opacity(Theme.playerUnsungOpacity)
                    )
                    .italic(line.isCredit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .accessibilityLabel(localized("Lyrics"))
                .accessibilityValue(Self.bandText(of: line))
                .accessibilityHint(localized("Opens the full lyrics"))
                // A line change is a turn, not a crossfade (§2.4's
                // `captionTurnOut` / `captionTurnIn`, through `lyricLine`). By
                // row, so two lines stamped at one moment still turn, and the
                // voice reaching the line already shown turns nothing.
                .id(index)
                .transition(.lyricLine(reduceMotion: reduceMotion))
            } else {
                // The artist on its own line scrolls like the title when it
                // is longer than its room.
                MarqueeLine(room: layout.subtitleWidth, isActive: isLive && !reduceMotion, text: track.artist) {
                    Text(track.artist)
                }
                    .font(.system(size: PlayerLayout.subtitleSize, weight: .regular))
                    .tracking(Theme.tracking(forSize: PlayerLayout.subtitleSize))
                    .foregroundStyle(.white.opacity(Theme.playerArtistOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(track.artist)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(track.artist)
                    .id(-1)
                    .transition(.lyricLine(reduceMotion: reduceMotion))
            }
        }
        // Clipped, so a line turning out never crosses the title above it.
        .clipped()
        .opacity(media.isPlaying || !band.isOn ? 1 : Theme.playerPausedLyricOpacity)
        .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: band.index)
        .animation(Theme.contentAnimation, value: media.isPlaying)
    }

    /// The band is drawn when the Lyric Band setting is on *and* the song has
    /// synced lines to show (spec §4.3). Show Lyrics off is `availability ==
    /// .disabled`, so the band is never drawn then; a song whose words are
    /// still being looked for, missing, or unreadable has no band either — the
    /// status lives on the stage, one place for it (spec §5.4).
    static func drawsLyricBand(setting: Bool, availability: LyricsAvailability, state: LyricsStore.State) -> Bool {
        guard setting, case .ready = availability, case .synced(let lines) = state else { return false }
        return !lines.isEmpty
    }

    /// What the subtitle draws for a line: its first row. A bilingual LRC line
    /// carries its translation after a newline (`LocalLyricsDocument.parse`),
    /// and one 14 pt line drew it raw — the second row running into the first.
    static func bandText(of line: LyricsStore.Line) -> String {
        LyricTranslation.rows(of: line.text).primary
    }

    /// What the sung line draws for one reading of the clock, or nil when there
    /// are no lines to show. Its row is the line being sung, through the same
    /// `LyricSweep.resolve` as the stage and the lock card; the lyric lab calls
    /// this function rather than a copy of its arithmetic.
    ///
    /// `readAhead` is "Show next line early" (`LyricSweep.readingMoment`): the
    /// player's line is the one surface besides the island's caption that holds
    /// a single sung line, so it turns to the next a beat before the voice.
    static func captionResolution(
        lines: [LyricsStore.Line], inputs: LyricInputs, readAhead: LyricReadAhead = .off
    ) -> LyricResolution? {
        guard !lines.isEmpty else { return nil }
        return LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: readAhead)
    }

    // MARK: - Times and progress

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    /// The elapsed and remaining labels' font: SF Pro Rounded 11 medium,
    /// tabular, white 0.40 (§19.6).
    static let timeFont = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()

    /// The times either side of the bar (spec §19.6), or — for a stream with no
    /// length — LIVE where the times go and a static track (§4.6). A scrubber
    /// with no length reads 0:00 / 0:00 and refuses to be dragged.
    @ViewBuilder
    private var progressRow: some View {
        let layout = layout
        let timesBox = Self.textBox(
            x: layout.elapsedLeading, baseline: layout.timesTop + 11, width: 60, size: 11, weight: .medium
        )
        if media.duration > 0 {
            let shown = previewFraction.map { $0 * media.duration } ?? min(media.labelPosition, media.duration)
            Text(formatTime(shown))
                .font(Self.timeFont)
                .foregroundStyle(previewFraction == nil
                                 ? Color.white.opacity(Theme.playerTimeOpacity) : Color.white.opacity(0.9))
                .frame(width: timesBox.width, height: timesBox.height, alignment: .leading)
                .offset(x: layout.elapsedLeading, y: layout.timesTop)
                .accessibilityHidden(true)
            Text("-" + formatTime(max(0, media.duration - shown)))
                .font(Self.timeFont)
                .foregroundStyle(.white.opacity(Theme.playerTimeOpacity))
                .frame(width: timesBox.width, height: timesBox.height, alignment: .trailing)
                .offset(x: layout.timesTrailing - timesBox.width, y: layout.timesTop)
                .accessibilityHidden(true)
            scrubber
                .placedAt(layout.progress.insetBy(dx: 0, dy: -8))
        } else {
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(height: 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .offset(x: layout.elapsedLeading, y: layout.progress.midY - 6)
            Capsule()
                .fill(.white.opacity(Theme.playerTrackOpacity))
                .placedAt(layout.progress)
                .accessibilityHidden(true)
        }
    }

    private var scrubber: some View {
        let layout = layout
        let width = layout.progress.width
        let filled = width * progress
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: PlayerLayout.progressRadius, style: .continuous)
                .fill(.white.opacity(Theme.playerTrackOpacity))
                .frame(height: layout.progress.height)
            // Deliberately unanimated: a seek has to land under the cursor at
            // once. Smoothness comes from the tick rate instead.
            RoundedRectangle(cornerRadius: PlayerLayout.progressRadius, style: .continuous)
                .fill(.white.opacity(Theme.playerFillOpacity))
                .frame(width: max(filled, layout.progress.height), height: layout.progress.height)
                .opacity(filled > 0 ? 1 : 0)
            if scrubHover {
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(filled - 5.5, 0), width - 11))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
        }
        .frame(maxHeight: .infinity)
        // 23 pt to grab and 7 to draw (F-014): the strip sits near the top of
        // the screen, and a 7 pt target had to be aimed at.
        .contentShape(Rectangle())
        .onHover { inside in
            scrubHover = inside
            previewArmTask?.cancel()
            guard inside else {
                previewArmed = false
                return
            }
            previewArmTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ScrubPreview.dwell))
                guard !Task.isCancelled else { return }
                previewArmed = true
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0 else { return }
                    scrubbing = min(max(value.location.x / width, 0), 1)
                }
                .onEnded { value in
                    guard width > 0 else { return }
                    let target = min(max(value.location.x / width, 0), 1)
                    // Seek first: clearing `scrubbing` beforehand would drop the
                    // bar back to the old position for a frame.
                    media.seek(to: media.duration * target)
                    scrubbing = nil
                }
        )
        .animation(Theme.contentAnimation, value: scrubHover)
        // A capsule with a drag gesture is nothing to assistive tech; see
        // `playbackPositionAccessibility` for why it is a slider.
        .playbackPositionAccessibility(
            shown: progress * media.duration,
            duration: media.duration,
            position: { media.position },
            seek: { media.seek(to: $0) }
        )
    }

    /// Kept for the lock card and the tests that measure an hour-long song's
    /// times: 26 and 30 for a song, wider for one whose times carry another
    /// digit.
    static func timeWidths(duration: TimeInterval) -> (elapsed: CGFloat, remaining: CGFloat) {
        duration >= 3600 ? (52, 52) : (26, 30)
    }

    // MARK: - Controls

    /// What the Favourite star can do for this song (§19.6): Music's, through
    /// the scripting bridge; Spotify's, through the connected account's
    /// library; or nothing, and then there is no star and the other four keep
    /// their places.
    enum Favourite: Equatable {
        case music(isOn: Bool)
        /// `isOn` is nil while the library has not answered.
        case spotify(trackID: String, isOn: Bool?)

        var isOn: Bool {
            switch self {
            case .music(let isOn): return isOn
            case .spotify(_, let isOn): return isOn ?? false
            }
        }

        static func resolve(
            musicFavorite: Bool?, spotifyTrackID: String?, spotifyCanSave: Bool, saved: [String: Bool]
        ) -> Favourite? {
            if let musicFavorite { return .music(isOn: musicFavorite) }
            if spotifyCanSave, let id = spotifyTrackID { return .spotify(trackID: id, isOn: saved[id]) }
            return nil
        }
    }

    private var favourite: Favourite? {
        let canSave = spotify.map { $0.isConnected && !$0.apiBlocked && !$0.tokenUnavailable } ?? false
        return Favourite.resolve(
            musicFavorite: media.musicFavorite, spotifyTrackID: media.spotifyTrackID,
            spotifyCanSave: canSave, saved: spotify?.saved ?? [:]
        )
    }

    @ViewBuilder
    private var controls: some View {
        let layout = layout
        if let favourite {
            favouriteButton(favourite)
                .placedAt(layout.target(.favourite), alignment: .center)
        }
        transportButton(.previous, symbol: "backward.fill", label: localized("Previous Track"), enabled: media.canSkip) {
            media.previous()
        }
        .placedAt(layout.target(.previous), alignment: .center)
        transportButton(
            .playPause, symbol: media.isPlaying ? "pause.fill" : "play.fill",
            label: media.isPlaying ? localized("Pause") : localized("Play"), enabled: true
        ) {
            media.togglePlayPause()
        }
        .placedAt(layout.target(.playPause), alignment: .center)
        transportButton(.next, symbol: "forward.fill", label: localized("Next Track"), enabled: media.canSkip) {
            media.next()
        }
        .placedAt(layout.target(.next), alignment: .center)
        if let output = layout.output {
            PlayerOutputButton(
                audio: audio, target: PlayerLayout.hitTarget,
                glyph: PlayerLayout.Control.output.glyph, color: .white.opacity(Theme.playerSecondaryControlOpacity)
            )
            .placedAt(output, alignment: .center)
        }
    }

    private func transportButton(
        _ control: PlayerLayout.Control, symbol: String, label: String, enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: control.glyph.width, height: control.glyph.height)
                .foregroundStyle(.white.opacity(Theme.playerTransportOpacity))
                // Replaced, not swapped: a hard cut on the control the eye is
                // resting on is the most visible non-native moment there is.
                .symbolSwap(value: symbol, reduceMotion: reduceMotion)
        }
        .buttonStyle(TransportGlyphStyle(size: PlayerLayout.hitTarget))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(Theme.contentAnimation, value: enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func favouriteButton(_ favourite: Favourite) -> some View {
        let label = favourite.isOn ? localized("Remove from Favorites") : localized("Favorite")
        let known: Bool = {
            if case .spotify(_, nil) = favourite { return false }
            return true
        }()
        return Button {
            switch favourite {
            case .music: media.toggleMusicFavorite()
            case .spotify(let id, _): _ = spotify?.toggleSaved(trackID: id)
            }
        } label: {
            Image(systemName: favourite.isOn ? "star.fill" : "star")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: PlayerLayout.Control.favourite.glyph.width, height: PlayerLayout.Control.favourite.glyph.height)
                .foregroundStyle(.white.opacity(Theme.playerSecondaryControlOpacity))
                .symbolSwap(value: favourite.isOn, reduceMotion: reduceMotion)
                // Until the library has answered, the star says it is asking
                // rather than claiming the song is not saved.
                .opacity(known ? 1 : 0.45)
        }
        .buttonStyle(TransportGlyphStyle(size: PlayerLayout.hitTarget))
        .disabled(!known)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Nothing playing (spec §4.8, in §19.6's frame)

    /// What the empty player says, apart from any drawing, so which status
    /// wins is something a test can read.
    enum EmptyStateMessage: Equatable {
        /// Nothing the island could show is playing.
        case nothingPlaying
        /// The Now Playing reader is down, so only Music and Spotify can be
        /// seen at all — a browser could be playing and nobody would know.
        case readerDown
        /// Something is audibly playing, and Music Only is what keeps it off
        /// the island: a YouTube tab, SoundCloud in a browser, a file in IINA.
        case hiddenByMusicOnly

        var headline: String {
            switch self {
            case .nothingPlaying, .readerDown: return localized("Nothing is playing.")
            case .hiddenByMusicOnly: return localized("Something is playing that Music Only keeps off the island.")
            }
        }

        /// The line under the headline (spec §4.8): what to do, what is wrong,
        /// or what the island chose not to show.
        var caption: String {
            switch self {
            case .nothingPlaying: return localized("Start a song in Music or Spotify, or open one here.")
            case .readerDown: return localized("Only Music and Spotify can be seen right now.")
            case .hiddenByMusicOnly: return localized("Videos and films stay off the island.")
            }
        }

        /// The reader-down state's pointer to where it is explained and fixed —
        /// Settings › Music — drawn under the buttons. The reason and Try Again
        /// live there and nowhere else: one failure surface (spec §4.8).
        var footnote: String? {
            switch self {
            case .readerDown: return localized("Settings › Music says why, with Try Again.")
            case .nothingPlaying, .hiddenByMusicOnly: return nil
            }
        }

        /// Which buttons the state offers: a player to open, or the one switch
        /// that decides what the island may show.
        var offersSettings: Bool { self == .hiddenByMusicOnly }

        /// Whether the state may offer to open this app. With the reader down
        /// only `PlayerBridge` works, and it speaks to Music and Spotify alone.
        func offersToOpen(_ bundleID: String) -> Bool {
            switch self {
            case .readerDown: return PlayerApp.allCases.contains { $0.bundleID == bundleID }
            case .nothingPlaying, .hiddenByMusicOnly: return true
            }
        }
    }

    /// The reader being down wins over the filter because it explains more:
    /// with the helper gone, the filter is not what hides a browser (J-007).
    static func emptyStateMessage(
        fallback: NowPlayingRouteFailure?, otherMediaPlaying: Bool, musicOnly: Bool
    ) -> EmptyStateMessage {
        if fallback != nil { return .readerDown }
        if otherMediaPlaying && musicOnly { return .hiddenByMusicOnly }
        return .nothingPlaying
    }

    /// With nothing playing a click on the island opens Tools (§19.6), so the
    /// player is empty only when somebody asked for it by name, or the song
    /// ended while it was open. It keeps the player's frame: the well where the
    /// cover goes, the status and one line of why beside it, and the remedy on
    /// the controls row.
    private var emptyState: some View {
        let message = Self.emptyStateMessage(
            fallback: media.fallbackReason,
            otherMediaPlaying: media.otherMediaIsPlaying,
            musicOnly: media.musicOnly()
        )
        let layout = layout
        let frames = PlayerLayout.emptyFrames(for: message)
        let offers = Self.openOffers(from: icons.installedMusicApps(), bodyWidth: layout.bodyWidth, message: message)
        return ZStack(alignment: .topLeading) {
            Color.clear
            MissingCoverWell(cornerRadius: PlayerLayout.coverRadius, noteSize: 22)
                .placedAt(layout.emptyWell)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(message.headline)
                    .islandFont(frames.headlineSize, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(message.caption)
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: frames.text.width, alignment: .topLeading)
            .offset(x: frames.text.minX, y: frames.text.minY)

            HStack(spacing: PlayerLayout.EmptyFrames.buttonSpacing) {
                if message.offersSettings {
                    Button(action: openMusicOnlySetting) {
                        Text(localized("Open Settings"))
                    }
                    .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: PlayerLayout.EmptyFrames.buttonHeight))
                } else {
                    ForEach(offers.apps, id: \.bundleID) { app in
                        Button {
                            NSWorkspace.shared.open(app.url)
                        } label: {
                            HStack(spacing: PlayerLayout.openButtonIconGap) {
                                if offers.form.showsIcon {
                                    AppIconImage(image: app.icon, side: PlayerLayout.openButtonIconSide)
                                }
                                Text(localized("Open %@", app.name))
                            }
                        }
                        .buttonStyle(OfferButtonStyle(
                            horizontalPadding: offers.form.horizontalPadding,
                            fixedHeight: PlayerLayout.EmptyFrames.buttonHeight
                        ))
                    }
                }
            }
            .frame(width: frames.buttons.width, height: frames.buttons.height, alignment: .leading)
            .offset(x: frames.buttons.minX, y: frames.buttons.minY)

            if let footnote = message.footnote, let footer = frames.footer {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(footnote).lineLimit(1)
                }
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .frame(width: footer.width, alignment: .leading)
                .offset(x: footer.minX, y: footer.minY)
            }
        }
    }

    /// The music apps that get an "Open …" button and the form they are drawn
    /// in (`PlayerLayout.openButtonRow`): the installed ones the state may
    /// offer, in `AppIcons.order`, Apple Music and Spotify always.
    static func openOffers(
        from apps: [AppIcons.Installed], bodyWidth: CGFloat = PlayerLayout.referenceBodyWidth,
        message: EmptyStateMessage = .nothingPlaying
    ) -> PlayerLayout.OpenButtonRow {
        PlayerLayout.openButtonRow(
            apps.filter { message.offersToOpen($0.bundleID) },
            room: PlayerLayout.openButtonsRoom(bodyWidth: bodyWidth)
        ) {
            PlayerLayout.measuredLabelWidth(localized("Open %@", $0.name))
        }
    }
}

// MARK: - A cover that is not coming

/// The well that stands where a missing cover goes (spec §4.7): white 0.08 with a
/// `music.note` in the quaternary white. Its own view so a test can draw it
/// without waiting out the 2.5 s the pane gives a cover to arrive.
struct MissingCoverWell: View {
    let cornerRadius: CGFloat
    var noteSize: CGFloat = Theme.playerCoverNoteSize

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.coverMissingWell)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: noteSize))
                    .foregroundStyle(Theme.quaternary)
            )
    }
}

// MARK: - Placement

extension View {
    /// Puts the view in `rect`, in its container's coordinates: sized to it,
    /// aligned inside it, and offset to its corner. The surfaces place their
    /// elements by the frames their layouts give rather than by stacking, so
    /// the frame a test holds is the frame drawn.
    func placedAt(_ rect: CGRect, alignment: Alignment = .leading) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - Output

/// The Output button: the glyph of the device the sound goes to now — in the
/// player's 42 pt target at 28 × 27 (§19.6), or the stage foot's 28 pt well —
/// opening the NSMenu of devices under it. Nothing is chosen, and
/// nothing changes on the Mac, until a row is picked.
///
/// It was `airplay.audio`, which the owner read as AirDrop (2026-10-16). The
/// glyph is now the current device's own — AirPods, the laptop, a display — the
/// way the Now Playing route button on iOS shows the AirPods it is routed to,
/// so the button says "output" by showing *which* output. It follows the watch:
/// `audio` is observed, so a device picked here, plugged in or unplugged
/// redraws it without anything asking.
struct PlayerOutputButton: View {
    let audio: AudioWatch
    /// The square the button answers in.
    var target: CGFloat = StageToolFrames.side
    /// The glyph's drawn size, fitted; nil draws it at the stage foot's 13 pt.
    var glyph: CGSize? = nil
    var color: Color = Theme.secondary
    /// What the button draws, derived from the watch and published only when it
    /// changes. The button used to observe the whole watch, which also
    /// publishes the volume, and redrew on every step of the volume keys.
    @StateObject private var state: OutputButtonState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var holder: BuiltOnce<OutputMenuPresenter>
    private var presenter: OutputMenuPresenter { holder.value }

    init(audio: AudioWatch, target: CGFloat = StageToolFrames.side, glyph: CGSize? = nil, color: Color? = nil) {
        self.audio = audio
        self.target = target
        self.glyph = glyph
        self.color = color ?? Theme.secondary
        _state = StateObject(wrappedValue: OutputButtonState(audio: audio))
        // Built once (`BuiltOnce`): this runs on every body pass of the pane.
        _holder = StateObject(wrappedValue: BuiltOnce {
            OutputMenuPresenter(controller: OutputMenuController(audio: audio))
        })
    }

    /// The glyph for the device now playing; a plain speaker until the watch
    /// has read the machine, or for a device the list does not hold.
    static func symbol(outputs: [AudioOutputs.Output], current: AudioDeviceID?) -> String {
        AudioOutputs.symbol(outputs: outputs, current: current, fallback: AudioOutputs.outputFallbackSymbol)
    }

    var body: some View {
        let symbol = state.value.symbol
        let device = state.value.name
        Button { presenter.present() } label: {
            Group {
                if let glyph {
                    Image(systemName: symbol)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: glyph.width, height: glyph.height)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(color)
            // A route changes when a device is picked or unplugged; the glyph
            // swaps the way the lock card's does (Reduce Motion: a plain change).
            .symbolSwap(value: symbol, reduceMotion: reduceMotion)
            .frame(width: target, height: target)
            .contentShape(RoundedRectangle(cornerRadius: StageToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .background(OutputMenuAnchor(presenter: presenter))
        .help(device ?? localized("Sound Output"))
        // The lock card's name for the same control.
        .accessibilityLabel(localized("Sound Output"))
        // Where the sound goes now, which the glyph alone cannot say.
        .accessibilityValue(device ?? "")
    }
}

/// The Output button's face — the current device's glyph and name — as the
/// watch's `outputs` and `current` give it, republished only when it differs.
/// A volume or mute change moves neither, so the button does not redraw for it.
@MainActor
final class OutputButtonState: ObservableObject {
    struct Value: Equatable {
        var symbol: String
        var name: String?
    }

    @Published private(set) var value: Value
    private var subscription: AnyCancellable?

    init(audio: AudioWatch) {
        value = Self.value(outputs: audio.outputs, current: audio.current)
        // `@Published` emits the new value as it is about to be stored, so the
        // pair is taken from the emission, not read back from the watch.
        subscription = audio.$outputs.combineLatest(audio.$current)
            .map { Self.value(outputs: $0, current: $1) }
            .removeDuplicates()
            .sink { [weak self] in self?.value = $0 }
    }

    static func value(outputs: [AudioOutputs.Output], current: AudioDeviceID?) -> Value {
        Value(
            symbol: PlayerOutputButton.symbol(outputs: outputs, current: current),
            name: LockScreenCard.outputName(outputs: outputs, current: current)
        )
    }
}

/// Equal when everything it draws from is: the same objects, the same values,
/// and the bindings holding the same value. The closures are left out on
/// purpose — they are rebuilt on every pass of the root view and so are never
/// equal, which made SwiftUI re-run this whole pane on every frame of a page
/// swipe, once per frame for each of the two pages on screen (measured
/// 2026-10-18: 30 bodies each over a 30-frame swipe). Each one only calls into
/// the view model, or reads Reduce Motion through `SystemAppearance` when it
/// is called, so a kept copy does exactly what a fresh one would. Its own
/// state and observed objects still redraw it as ever; this only stops a
/// parent's pass from doing it for nothing (`NotchContentView.pane(for:)`).
extension MediaPane: @MainActor Equatable {
    static func == (lhs: MediaPane, rhs: MediaPane) -> Bool {
        lhs.media === rhs.media
            && lhs.lyrics === rhs.lyrics
            && lhs.audio === rhs.audio
            && lhs.spotify === rhs.spotify
            && lhs.icons === rhs.icons
            && lhs.morph == rhs.morph
            && lhs.coverTint.isEqual(rhs.coverTint)
            && lhs.isLive == rhs.isLive
    }
}

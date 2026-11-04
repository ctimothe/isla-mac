import AppKit
import SwiftUI

/// Where everything on the lyrics stage goes (spec §19.6, board `R2-Lyrics`),
/// in the content's coordinates: the board's body coordinates less the
/// reference notch's 38, which is what `SurfaceLayout.inContent` does. The
/// header row — the playing app's icon and Tools — is the shell's, drawn in
/// the strip above.
struct StageLayout: Equatable {
    var bodyWidth: CGFloat
    /// Show Translation is in the row, which makes five tools: at the narrow
    /// end of the width setting they then close up rather than run into the
    /// transport (`toolSpacing`).
    var translationShown = false

    /// The lines: from x 24, `bw − 48` wide, from the content's top to 8 above
    /// the hairline, so the bottom fade ends before the foot begins.
    var lines: CGRect {
        CGRect(x: 24, y: 0, width: bodyWidth - 48, height: Self.linesHeight)
    }

    static let linesHeight: CGFloat = 268

    /// The sung line's centre in the lines' own coordinates: its top at body
    /// y 138 and a 28 pt line, so 138 − 38 + 14.
    static let readingCentre: CGFloat = 114

    /// The hairline over the foot: (20, 314), `bw − 40` × 0.5.
    var hairline: CGRect { SurfaceLayout.inContent(CGRect(x: 20, y: 314, width: bodyWidth - 40, height: 0.5)) }

    /// The cover, 40 × 40 at (24, 330), radius 8.
    var cover: CGRect { SurfaceLayout.inContent(CGRect(x: 24, y: 330, width: 40, height: 40)) }
    static let coverRadius: CGFloat = 8

    /// The transport's three hit targets — Previous 32, Play / Pause 34, Next
    /// 32, each 30 tall and 6 apart — centred on `bw / 2` at y 334.
    enum Transport: CaseIterable {
        case previous, playPause, next

        var width: CGFloat { self == .playPause ? 34 : 32 }

        /// The hit target: the well's size, which no longer draws a fill.
        var hitTarget: CGSize { CGSize(width: width, height: StageLayout.transportHeight) }
    }

    static let transportHeight: CGFloat = 30
    static let transportSpacing: CGFloat = 6

    var transportWidth: CGFloat {
        Transport.allCases.reduce(0) { $0 + $1.width } + Self.transportSpacing * CGFloat(Transport.allCases.count - 1)
    }

    func transport(_ which: Transport) -> CGRect {
        var x = (bodyWidth - transportWidth) / 2
        for item in Transport.allCases {
            if item == which { break }
            x += item.width + Self.transportSpacing
        }
        return SurfaceLayout.inContent(CGRect(x: x, y: 334, width: which.width, height: Self.transportHeight))
    }

    /// The title, 13 semibold, at (76, 332), and the artist, 12 regular, at
    /// (76, 350): both end 8 before the transport, which they truncate for.
    var title: CGRect { SurfaceLayout.inContent(CGRect(x: 76, y: 332, width: textWidth, height: 16)) }
    var artist: CGRect { SurfaceLayout.inContent(CGRect(x: 76, y: 350, width: textWidth, height: 15)) }
    private var textWidth: CGFloat { max(0, transport(.previous).minX - 8 - 76) }

    /// The tools at y 336, 28 × 28, 6 apart, the last ending at `bw − 26`:
    /// Show Translation (when a translation is possible), More, Output,
    /// Volume, Hide Lyrics — so counted from the right, Hide Lyrics is 0.
    /// Volume sits beside Hide Lyrics, Output left of it (amended 2026-10-26,
    /// order swapped the same day): the speaker is the nearer to the thumb.
    enum Tool: Int, CaseIterable {
        case hideLyrics, volume, output, more, translation
    }

    func tool(_ which: Tool) -> CGRect {
        let side = StageToolFrames.side
        let x = bodyWidth - 26 - side - CGFloat(which.rawValue) * (side + toolSpacing)
        return SurfaceLayout.inContent(CGRect(x: x, y: 336, width: side, height: side))
    }

    /// The gap between tools: the board's 6, or less where the row would
    /// otherwise come within 6 of Next. Five tools at 6 apart need a body of
    /// 502; the setting goes down to 480, where with Show Translation in the
    /// row the gap is 3.25 — the targets still 28 wide and never overlapping.
    var toolSpacing: CGFloat {
        let count = CGFloat(translationShown ? Tool.allCases.count : Tool.allCases.count - 1)
        let side = StageToolFrames.side
        let transportEnd = (bodyWidth + transportWidth) / 2
        let room = bodyWidth - 26 - count * side - (transportEnd + Self.toolClearance)
        return min(StageToolFrames.spacing, max(Self.minimumToolSpacing, room / (count - 1)))
    }

    static let toolClearance: CGFloat = 6
    static let minimumToolSpacing: CGFloat = 2

    /// The volume slider while it is open: from the title's x to Next's right
    /// edge, 30 tall on the transport's row. It stands where the title and the
    /// transport were, which fade for it — the only span in the foot wide
    /// enough for a bar a finger can place (219 pt at 480), and the song's
    /// cover stays to say what is being turned up.
    var volumeSlider: CGRect {
        let end = (bodyWidth + transportWidth) / 2
        return SurfaceLayout.inContent(CGRect(x: 76, y: 334, width: end - 76, height: Self.transportHeight))
    }

    /// The fallback line under an open slider, when the player refused
    /// Automation: one line of 11 pt between the slider and the progress.
    var volumeNotice: CGRect {
        let slider = volumeSlider
        return CGRect(x: slider.minX, y: slider.maxY + 1, width: slider.width, height: 13)
    }

    /// The progress, (24, 384), `bw − 48` × 3, radius 1.5.
    var progress: CGRect { SurfaceLayout.inContent(CGRect(x: 24, y: 384, width: bodyWidth - 48, height: 3)) }
    static let progressRadius: CGFloat = 1.5
    /// How far the bar's grab area extends above and below it: 8, so 19 pt tall
    /// as the player's is 23, and clear of the transport's wells (they end at
    /// body y 364; the area starts at 376).
    static let progressGrabInset: CGFloat = 8
}

/// The lyrics stage (spec §19.6): six lines of the song at 22 bold over a
/// foot that carries the song, its transport and the stage's tools. One
/// timeline and one renderer, as everywhere — the lines are `LyricsStage`,
/// which the lock card's column shares its rows with.
struct LyricsStageSurface: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    var bodyWidth: CGFloat
    var localLookup: LocalLyricsLookup? = nil
    var turnOnLyrics: () -> Void = {}
    var turnOnOnlineLyrics: () -> Void = {}
    var importLocalFile: () -> Void = {}
    var notice: String? = nil
    var selectLocalCandidate: (LocalLyricsCandidate) -> Void = { _ in }
    var removeLocalBinding: () -> Void = {}
    var localLibrary: LocalLyricsLibrary?
    var currentLocalTrackIdentity: () -> LocalTrackIdentity? = { nil }
    var invalidLine: () -> Int? = { nil }
    var editingSession: Binding<LocalLyricsEditor.EditingSession?> = .constant(nil)
    /// The More menu and the translation menu: the model's, built once. Nil
    /// where the stage is drawn on its own, which then has no menus to open.
    var moreMenu: LyricsMoreMenuController?
    var translateMenu: LyricsTranslateMenuController?
    var hideLyrics: () -> Void = {}
    ///
    /// Held, not observed (2026-10-25): the pane only starts and stops it and
    /// hands it to the Output button, which subscribes to the route alone
    /// (`OutputButtonState`). Observing the whole watch redrew the player for
    /// every change it published.
    var audio: AudioWatch = MediaPane.quietAudio()
    @ObservedObject var translation: LyricTranslation = .idle
    var coverTint: NSColor = CoverTint.fallback.nsColor
    /// The song as the panel draws it (`NowPlayingPresenter`), nil outside
    /// the panel, where the stage draws the controller live.
    var nowPlaying: NowPlayingPresenter.Frame? = nil
    /// The speaker's control (owner 2026-10-26): Music's or Spotify's own
    /// volume, the Mac's for any other source. One for the app, so the glyph
    /// keeps the last level it read; it reads nothing while it is closed.
    @ObservedObject var volume: PlayerVolume = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(NotchViewModel.volumeAndOutputKey) private var outputButtonOn = true
    /// The line a bound file was refused at, read when the state says it was.
    @State private var invalidFileLine: Int?

    private var layout: StageLayout {
        StageLayout(bodyWidth: bodyWidth, translationShown: translation.isEnabled && translateMenu != nil)
    }

    var body: some View {
        let layout = layout
        ZStack(alignment: .topLeading) {
            Color.clear

            LyricsStage(
                media: media,
                lyrics: lyrics,
                localLookup: localLookup,
                turnOnLyrics: turnOnLyrics,
                turnOnOnlineLyrics: turnOnOnlineLyrics,
                importLocalFile: importLocalFile,
                notice: notice,
                selectLocalCandidate: selectLocalCandidate,
                removeLocalBinding: removeLocalBinding,
                editLocalLyrics: { candidate in
                    guard localLibrary != nil else { return }
                    editingSession.wrappedValue = LocalLyricsEditor.EditingSession(
                        candidate: candidate, identity: currentLocalTrackIdentity()
                    )
                },
                editBlankLyrics: {
                    guard let localLibrary else { return }
                    // On the file's own lines where they can be read, so the one
                    // bad stamp is a row to fix and not a reason to start over.
                    editingSession.wrappedValue = LocalLyricsEditor.EditingSession.unreadable(
                        identity: currentLocalTrackIdentity(), library: localLibrary
                    )
                },
                invalidLine: invalidFileLine,
                dismiss: hideLyrics,
                readingCentre: StageLayout.readingCentre,
                translation: translation,
                heldClock: nowPlaying?.held
            )
            .placedAt(layout.lines, alignment: .topLeading)

            Rectangle()
                .fill(Theme.stageHairline)
                .placedAt(layout.hairline)
                .accessibilityHidden(true)

            foot(layout)
        }
        // A click anywhere but the slider, its speaker or its line folds an
        // open slider, as a click outside Control Center's does. Simultaneous,
        // so the click still does what it would have — a lyric line still
        // seeks — rather than being spent on closing.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { tap in
                guard volume.isOpen else { return }
                let keep = [layout.volumeSlider, layout.tool(.volume), layout.volumeNotice]
                if !keep.contains(where: { $0.contains(tap.location) }) { volume.close() }
            }
        )
        .animation(Theme.trackSwap(reduceMotion: reduceMotion), value: volume.isOpen)
        .task(id: lyrics.availability) {
            if case .invalidLocalFile = lyrics.availability {
                invalidFileLine = invalidLine()
            } else if invalidFileLine != nil {
                invalidFileLine = nil
            }
        }
        .onAppear {
            volume.sourceChanged(bundleID: media.displayedSourceBundleID)
            media.refreshPlaybackModes()
            if outputButtonOn { audio.start() }
            if DebugTrail.openLyrics {
                DebugTrail.note("LyricsStageSurface track=\(media.track?.title ?? "none")")
            }
        }
        .onChange(of: outputButtonOn) { _, on in
            if on { audio.start() } else { audio.stop() }
        }
        .onChange(of: media.track?.key) { _, _ in
            volume.sourceChanged(bundleID: media.displayedSourceBundleID)
        }
        .onChange(of: media.sourceName) { _, _ in
            volume.sourceChanged(bundleID: media.displayedSourceBundleID)
        }
        .onDisappear {
            audio.stop()
            volume.close()
        }
        .sheet(item: editingSession) { session in
            if let localLibrary {
                LocalLyricsEditorView(
                    session: session,
                    editor: LocalLyricsEditor(library: localLibrary),
                    onSaved: { _ in editingSession.wrappedValue = nil },
                    onDismiss: { editingSession.wrappedValue = nil }
                )
            }
        }
    }

    // MARK: - The foot

    @ViewBuilder
    private func foot(_ layout: StageLayout) -> some View {
        cover
            .placedAt(layout.cover)
            .accessibilityHidden(true)

        // The open slider stands where the song's name and the transport were
        // (`StageLayout.volumeSlider`); they fade for it and come back when it
        // folds, three seconds after the last touch.
        if volume.isOpen {
            StageVolumeSlider(volume: volume)
                .placedAt(layout.volumeSlider)
                .transition(.opacity)
            if let app = volume.refused {
                StageVolumeNotice(app: app)
                    .placedAt(layout.volumeNotice, alignment: .leading)
                    .transition(.opacity)
            }
        } else {
            songAndTransport(layout)
        }

        if translation.isEnabled, let translateMenu {
            TranslationToolButton(isShown: translation.isShown, controller: translateMenu) {
                translation.toggleShown()
            }
            .placedAt(layout.tool(.translation))
        }
        if let moreMenu {
            LyricsMoreButton(controller: moreMenu)
                .placedAt(layout.tool(.more))
        }
        if outputButtonOn {
            PlayerOutputButton(audio: audio)
                .placedAt(layout.tool(.output))
        }
        StageVolumeButton(volume: volume)
            .placedAt(layout.tool(.volume))
        HeaderIconButton(symbol: "quote.bubble.fill", label: localized("Hide Lyrics"), isOn: true, action: hideLyrics)
            .placedAt(layout.tool(.hideLyrics))

        progress(layout)
    }

    @ViewBuilder
    private func songAndTransport(_ layout: StageLayout) -> some View {
        if let track = media.shownTrack(nowPlaying) {
            Text(track.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(Theme.tracking(forSize: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(track.title)
                .trackSwapText(track.key, reduceMotion: reduceMotion)
                .placedAt(layout.title)
                .transition(.opacity)
            Text(track.artist)
                .font(.system(size: 12, weight: .regular))
                .tracking(Theme.tracking(forSize: 12))
                .foregroundStyle(.white.opacity(Theme.stageArtistOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(track.artist)
                .trackSwapText(track.key, reduceMotion: reduceMotion)
                .placedAt(layout.artist)
                .transition(.opacity)
        }

        // The player's own three buttons, in the stage's wells: the glyphs are
        // the player's, scaled to the 30 pt row, and the 32 / 34 × 30 hit
        // targets are what they were (`TransportGlyphButton`).
        TransportGlyphButton(
            .previous, enabled: media.canSkip, hitTarget: StageLayout.Transport.previous.hitTarget
        ) { media.previous() }
            .placedAt(layout.transport(.previous))
            .transition(.opacity)
        TransportGlyphButton(
            .playPause, isPlaying: media.shownIsPlaying(nowPlaying), hitTarget: StageLayout.Transport.playPause.hitTarget
        ) { media.togglePlayPause() }
            .placedAt(layout.transport(.playPause))
            .transition(.opacity)
        TransportGlyphButton(
            .next, enabled: media.canSkip, hitTarget: StageLayout.Transport.next.hitTarget
        ) { media.next() }
            .placedAt(layout.transport(.next))
            .transition(.opacity)
    }

    private var cover: some View {
        Color.clear
            .overlay {
                if let image = media.shownArtwork(nowPlaying) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .trackSwapCover(media.shownTrack(nowPlaying)?.key, reduceMotion: reduceMotion)
                } else {
                    MissingCoverWell(cornerRadius: StageLayout.coverRadius, noteSize: 16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StageLayout.coverRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StageLayout.coverRadius, style: .continuous)
                    .strokeBorder(Theme.coverEdge, lineWidth: 0.5)
            )
            // The swap's curve, for a cover landing after its song.
            .animation(Theme.trackSwap(reduceMotion: reduceMotion), value: media.shownArtwork(nowPlaying))
    }

    /// The progress: the cover's tint over white 0.18, 3 pt at rest.
    ///
    /// The player's scrubber (`PlaybackScrubber`) in a grab area 8 pt taller
    /// either side, so the bar can be dragged without being aimed at: it was
    /// drawn only, on the reasoning that a 3 pt bar under a row of buttons would
    /// be missed, and the owner could not seek from the page where a song is
    /// followed most closely (2026-10-24). The area is 19 pt tall and clear of
    /// the transport above it (its wells end 20 pt higher). A stream with no
    /// length keeps the static bar: there is nothing to seek in.
    @ViewBuilder
    private func progress(_ layout: StageLayout) -> some View {
        if media.shownDuration(nowPlaying) > 0 {
            PlaybackScrubber(
                media: media, width: layout.progress.width, trackHeight: layout.progress.height,
                radius: StageLayout.progressRadius,
                track: Theme.stageTrack, fill: Color(nsColor: coverTint),
                nowPlaying: nowPlaying
            )
            .placedAt(layout.progress.insetBy(dx: 0, dy: -StageLayout.progressGrabInset))
        } else {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StageLayout.progressRadius, style: .continuous)
                    .fill(Theme.stageTrack)
            }
            .placedAt(layout.progress)
            .accessibilityHidden(true)
        }
    }
}

import AppKit
import SwiftUI

/// Where everything on the lyrics stage goes (spec §19.6, board `R2-Lyrics`),
/// in the content's coordinates: the board's body coordinates less the
/// reference notch's 38, which is what `SurfaceLayout.inContent` does. The
/// header row — the playing app's icon and Tools — is the shell's, drawn in
/// the strip above.
struct StageLayout: Equatable {
    var bodyWidth: CGFloat

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

    /// The transport's three wells — Previous 32, Play / Pause 34, Next 32,
    /// each 30 tall and 6 apart — centred on `bw / 2` at y 334.
    enum Transport: CaseIterable {
        case previous, playPause, next

        var width: CGFloat { self == .playPause ? 34 : 32 }
    }

    static let transportHeight: CGFloat = 30
    static let transportSpacing: CGFloat = 6
    static let transportRadius: CGFloat = 8

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
    /// Show Translation (when a translation is possible), More, Output, Hide
    /// Lyrics — so counted from the right, Hide Lyrics is 0.
    enum Tool: Int, CaseIterable {
        case hideLyrics, output, more, translation
    }

    func tool(_ which: Tool) -> CGRect {
        let side = StageToolFrames.side
        let x = bodyWidth - 26 - side - CGFloat(which.rawValue) * (side + StageToolFrames.spacing)
        return SurfaceLayout.inContent(CGRect(x: x, y: 336, width: side, height: side))
    }

    /// The progress, (24, 384), `bw − 48` × 3, radius 1.5.
    var progress: CGRect { SurfaceLayout.inContent(CGRect(x: 24, y: 384, width: bodyWidth - 48, height: 3)) }
    static let progressRadius: CGFloat = 1.5
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
    @ObservedObject var audio: AudioWatch = MediaPane.quietAudio()
    @ObservedObject var translation: LyricTranslation = .idle
    var coverTint: NSColor = CoverTint.fallback.nsColor
    @AppStorage(NotchViewModel.volumeAndOutputKey) private var outputButtonOn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line a bound file was refused at, read when the state says it was.
    @State private var invalidFileLine: Int?

    private var layout: StageLayout { StageLayout(bodyWidth: bodyWidth) }

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
                translation: translation
            )
            .placedAt(layout.lines, alignment: .topLeading)

            Rectangle()
                .fill(Theme.stageHairline)
                .placedAt(layout.hairline)
                .accessibilityHidden(true)

            foot(layout)
        }
        .task(id: lyrics.availability) {
            if case .invalidLocalFile = lyrics.availability {
                invalidFileLine = invalidLine()
            } else if invalidFileLine != nil {
                invalidFileLine = nil
            }
        }
        .onAppear {
            media.refreshPlaybackModes()
            if outputButtonOn { audio.start() }
            if DebugTrail.openLyrics {
                DebugTrail.note("LyricsStageSurface track=\(media.track?.title ?? "none")")
            }
        }
        .onChange(of: outputButtonOn) { _, on in
            if on { audio.start() } else { audio.stop() }
        }
        .onDisappear { audio.stop() }
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

        if let track = media.track {
            Text(track.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(Theme.tracking(forSize: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(track.title)
                .placedAt(layout.title)
            Text(track.artist)
                .font(.system(size: 12, weight: .regular))
                .tracking(Theme.tracking(forSize: 12))
                .foregroundStyle(.white.opacity(Theme.stageArtistOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(track.artist)
                .placedAt(layout.artist)
        }

        transportButton(.previous, symbol: "backward.fill", label: localized("Previous Track"), enabled: media.canSkip) {
            media.previous()
        }
        .placedAt(layout.transport(.previous))
        transportButton(
            .playPause, symbol: media.isPlaying ? "pause.fill" : "play.fill",
            label: media.isPlaying ? localized("Pause") : localized("Play"), enabled: true
        ) {
            media.togglePlayPause()
        }
        .placedAt(layout.transport(.playPause))
        transportButton(.next, symbol: "forward.fill", label: localized("Next Track"), enabled: media.canSkip) {
            media.next()
        }
        .placedAt(layout.transport(.next))

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
        HeaderIconButton(symbol: "quote.bubble.fill", label: localized("Hide Lyrics"), isOn: true, action: hideLyrics)
            .placedAt(layout.tool(.hideLyrics))

        progress(layout)
    }

    private var cover: some View {
        Color.clear
            .overlay {
                if let image = media.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    MissingCoverWell(cornerRadius: StageLayout.coverRadius, noteSize: 16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StageLayout.coverRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StageLayout.coverRadius, style: .continuous)
                    .strokeBorder(Theme.coverEdge, lineWidth: 0.5)
            )
            .animation(Theme.artworkAnimation, value: media.artwork)
    }

    private func transportButton(
        _ which: StageLayout.Transport, symbol: String, label: String, enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .symbolSwap(value: symbol, reduceMotion: reduceMotion)
                .frame(width: which.width, height: StageLayout.transportHeight)
                .background(
                    RoundedRectangle(cornerRadius: StageLayout.transportRadius, style: .continuous)
                        .fill(Theme.stageTransportFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: StageLayout.transportRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The progress: the cover's tint over white 0.18. Drawn, not dragged —
    /// the player's bar is the one to seek with, and a 3 pt bar under a row
    /// of buttons would be aimed at and missed.
    private func progress(_ layout: StageLayout) -> some View {
        let fraction = media.duration > 0 ? min(max(media.position / media.duration, 0), 1) : 0
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: StageLayout.progressRadius, style: .continuous)
                .fill(Theme.stageTrack)
            RoundedRectangle(cornerRadius: StageLayout.progressRadius, style: .continuous)
                .fill(Color(nsColor: coverTint))
                .frame(width: layout.progress.width * fraction)
        }
        .placedAt(layout.progress)
        .accessibilityHidden(true)
    }
}

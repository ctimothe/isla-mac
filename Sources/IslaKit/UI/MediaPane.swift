import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    var localLookup: LocalLyricsLookup? = nil
    var retryLyrics: () -> Void = {}
    var turnOnLyrics: () -> Void = {}
    var turnOnOnlineLyrics: () -> Void = {}
    var importLocalFile: () -> Void = {}
    /// Why the last import from the lyrics page failed, for the page to say
    /// under its header. See `NotchViewModel.LyricsNotice`.
    var lyricsNotice: String? = nil
    var selectLocalCandidate: (LocalLyricsCandidate) -> Void = { _ in }
    var removeLocalBinding: () -> Void = {}
    var localLibrary: LocalLyricsLibrary?
    var currentLocalTrackIdentity: () -> LocalTrackIdentity? = { nil }
    /// Settings, scrolled to the Music section, for the empty tab's one remedy
    /// when Music Only is what keeps a playing source off the island.
    var openMusicOnlySetting: () -> Void = {}
    /// The namespace the cover travels in, when this pane is inside the panel.
    ///
    /// Optional because the pane is also rendered on its own — by the layout
    /// tests, with no pill above it and nothing to travel from. `nil` means
    /// "draw the cover where it lands and nothing else", which is what a pane
    /// with no island around it should do.
    var morph: Namespace.ID?
    /// Whether the pane is showing the lyrics page.
    ///
    /// A binding rather than this pane's own `@State`, because the page is a
    /// place the app can be *sent* and not just a toggle the pane owns: ⌃⌥⌘L
    /// opens the panel straight onto it. It defaults to a constant so the pane
    /// still renders standalone in the layout tests, where there is no panel
    /// to route anything and nowhere for the request to go.
    var showingLyrics: Binding<Bool> = .constant(false)
    /// The header's height above this pane — the notch's, 38 pt on a 14-inch
    /// MacBook Pro. The pane starts where the header ends, and the board's body
    /// coordinates are measured from the body's top, so this is the one number
    /// the conversion between the two needs (`PlayerLayout.inPane`). Defaults to
    /// the boards' own 38 for a pane rendered with no notch around it.
    var headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight
    /// The machine's audio state, for the volume slider and the Output menu. The
    /// default reads nothing and installs nothing: a pane built anywhere but the
    /// panel — a test, a render — must not reach the owner's output devices, even
    /// to read them. The panel hands in `NotchViewModel.playerAudio`.
    @ObservedObject var audio: AudioWatch = MediaPane.quietAudio()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Volume and Output, and Lyric Band: Settings › Music (spec §14). Read
    /// through `@AppStorage` so the switch in Settings redraws the player while
    /// it is on screen. Absent means the spec's default — **on** for both, and
    /// Volume and Output is the owner-waived exception to the default-off rule
    /// for system-wide settings (`NotchViewModel.volumeAndOutputEnabled`).
    @AppStorage(NotchViewModel.volumeAndOutputKey) private var volumeAndOutputOn = true
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
    /// Cursor x inside the bar while hovering, and the bar's own width, so the
    /// elapsed label can read the time under the pointer.
    @State private var hoverX: CGFloat?
    @State private var scrubWidth: CGFloat = 0

    /// Where the pointer (or the finger mid-drag) sits along the bar, 0...1.
    /// Nil when neither is on it, which is when the label goes back to saying
    /// where the song actually is.
    private var previewFraction: Double? {
        if let scrubbing { return scrubbing }
        guard scrubHover, previewArmed, let hoverX else { return nil }
        return ScrubPreview.fraction(x: hoverX, width: scrubWidth, duration: media.duration)
    }
    /// Set once the current track has waited long enough for artwork that it
    /// is evidently not coming. Some sources never publish a cover, and a
    /// shimmer that promises one forever reads as stuck, not loading.
    @State private var artworkWaitExpired = false
    /// What Edit was pressed on and for which song, captured at the press.
    /// The sheet used to read `currentLocalTrackIdentity()` in its content
    /// closure, which runs again on every pass of this body, so a track
    /// change while the editor was up re-aimed Save Copy at the new song
    /// (J-009).
    @State private var editingSession: LocalLyricsEditor.EditingSession?

    /// One line of the lyric band: 17 pt, the height both slots keep so a line
    /// turning out and the next turning in share a window that clips them.
    ///
    /// (The caption used to hold this slot whether or not there was a word to put
    /// in it, so a lyric arriving never moved the controls under a pointer already
    /// travelling towards them. The redesign trades that for the board's rule —
    /// with no lyric the band folds away and the block below rises by 20, spec
    /// §4.1 — and softens it: the shift is a 0.16 s ease, and a song whose words
    /// have not arrived lays out as a song without any until they do.)
    static let captionHeight: CGFloat = 17

    var body: some View {
        if let track = media.track {
            ZStack {
                if showingLyrics.wrappedValue {
                    // The Liquid Glass entrance: blur, scale and opacity settle
                    // together, so the stage materializes rather than pops.
                    LyricsStage(
                        media: media,
                        lyrics: lyrics,
                        localLookup: localLookup,
                        retry: retryLyrics,
                        turnOnLyrics: turnOnLyrics,
                        turnOnOnlineLyrics: turnOnOnlineLyrics,
                        importLocalFile: importLocalFile,
                        notice: lyricsNotice,
                        selectLocalCandidate: selectLocalCandidate,
                        removeLocalBinding: removeLocalBinding,
                        editLocalLyrics: { candidate in
                            guard localLibrary != nil else { return }
                            editingSession = LocalLyricsEditor.EditingSession(
                                candidate: candidate, identity: currentLocalTrackIdentity()
                            )
                        }
                    ) {
                        showingLyrics.wrappedValue = false
                    }
                    .transition(reduceMotion ? AnyTransition.opacity : .materialize)
                } else {
                    player(for: track)
                        .transition(reduceMotion ? AnyTransition.opacity : .materialize)
                }
            }
            .animation(Theme.paneAnimation, value: showingLyrics.wrappedValue)
            // Leaving the track folds the stage: the next song starts on the
            // player, and a stage left open for a track without lyrics would
            // open onto its own empty state.
            .onChange(of: track.key) { _, _ in showingLyrics.wrappedValue = false }
            .onAppear {
                media.refreshPlaybackModes()
                if volumeAndOutputOn { audio.start() }
                if DebugTrail.openLyrics {
                    DebugTrail.note("MediaPane track=\(track.title) showingLyrics=\(showingLyrics.wrappedValue)")
                }
            }
            // The watch follows the machine only while there is a slider or a menu
            // to show it in, and only while the pane is on screen: it reads, and
            // installs CoreAudio listeners, and writes nothing.
            .onChange(of: volumeAndOutputOn) { _, on in
                if on { audio.start() } else { audio.stop() }
            }
            .onDisappear { audio.stop() }
            .sheet(item: $editingSession) { session in
                if let localLibrary {
                    LocalLyricsEditorView(
                        session: session,
                        editor: LocalLyricsEditor(library: localLibrary),
                        onSaved: { _ in editingSession = nil },
                        onDismiss: { editingSession = nil }
                    )
                }
            }
        } else {
            emptyState
                .onAppear {
                    if DebugTrail.openLyrics {
                        DebugTrail.note("MediaPane EMPTY (no track)")
                    }
                }
        }
    }

    // MARK: - The player (spec §4)

    /// What the player is laid out with at this pane width. Everything below is
    /// placed by frames from this, in the pane's own coordinates — the board's
    /// body coordinates converted in one place (`PlayerLayout.inPane`).
    private func layout(paneWidth: CGFloat) -> PlayerLayout {
        PlayerLayout(
            bodyWidth: PlayerLayout.bodyWidth(paneWidth: paneWidth),
            headerHeight: headerHeight,
            hasLyricBand: drawsLyricBand,
            hasVolumeAndOutput: volumeAndOutputOn
        )
    }

    /// Whether the lyric band is on screen for the song now playing.
    private var drawsLyricBand: Bool {
        Self.drawsLyricBand(setting: lyricBandOn, availability: lyrics.availability, state: lyrics.state)
    }

    /// The band is drawn when the Lyric Band setting is on *and* the song has
    /// synced lines to show (spec §4.3). Show Lyrics off is `availability ==
    /// .disabled`, so the band is never drawn then; a song whose words are
    /// still being looked for, missing, or unreadable has no band either — the
    /// layout takes the no-lyric positions and the status lives on the lyrics
    /// page, one place for it.
    static func drawsLyricBand(setting: Bool, availability: LyricsAvailability, state: LyricsStore.State) -> Bool {
        guard setting, case .ready = availability, case .synced(let lines) = state else { return false }
        return !lines.isEmpty
    }

    /// The row after `index`, the band's second line, or nil at the last line.
    static func nextBandIndex(after index: Int, count: Int) -> Int? {
        index + 1 < count ? index + 1 : nil
    }

    private func player(for track: MediaController.Track) -> some View {
        GeometryReader { geo in
            let layout = layout(paneWidth: geo.size.width)
            ZStack(alignment: .topLeading) {
                // The pane's own size, so the children are placed from its
                // top-left corner whatever they measure.
                Color.clear

                artwork(for: track)
                    .placed(layout.inPane(layout.cover))

                // One line, tail-truncated, and the whole title as the tooltip:
                // a long title (the Russian one on `Music-Long-Title`) is cut at
                // `bw − 220` and never wraps into the band under it.
                Text(track.title)
                    .islandFont(.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(track.title)
                    .placed(layout.inPane(layout.title))
                Text(subtitle(for: track))
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle(for: track))
                    .placed(layout.inPane(layout.subtitle))

                if layout.hasLyricBand {
                    lyricBand(for: track, layout: layout)
                }

                progressRow
                    .placed(layout.inPane(layout.progress))

                modeButtons(layout: layout)
                transport
                    .placed(layout.inPane(layout.transport))

                if let volume = layout.volume {
                    PlayerVolumeSlider(audio: audio, trackKey: track.key)
                        .placed(layout.inPane(volume))
                }
                if let output = layout.output {
                    PlayerOutputButton(audio: audio, includesVolume: layout.volumeFoldsIntoMenu)
                        .placed(layout.inPane(output))
                }
                lyricsButton
                    .placed(layout.inPane(layout.lyrics))
            }
            // The block moving up when the band folds away is a short ease, so a
            // lyric arriving does not teleport the controls (spec §4.1).
            .animation(reduceMotion ? nil : Theme.contentAnimation, value: layout.hasLyricBand)
            // Title and artist arrive together, so the whole column can cross-
            // fade as one unit when the track changes.
            .animation(Theme.artworkAnimation, value: track.key)
        }
    }

    /// The system often repeats the title as the album name; showing
    /// "Artist — Title" twice reads like a bug.
    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Artwork

    /// The far end of the cover's travel from the pill.
    ///
    /// Both the size and the corner come from `Theme.artworkMetrics` rather than
    /// from numbers written here: this end hardcoded 118 pt at radius 14 while
    /// the pill hardcoded 22 pt at radius 6, in another file, and one object
    /// described twice is how it came to be drawn twice. (It is 132 pt since the
    /// redesign, spec §4.1.)
    ///
    /// Modifier order matters more than usual, and the base of the stack is
    /// `Color.clear` for a reason. The cover has to *accept* whatever size it is
    /// offered — the morph offers it the pill's size on the way in — and a view
    /// that states its own size is a view the effect cannot resize, which leaves
    /// a cover that slides into place without ever growing. `Color.clear` takes
    /// the proposal exactly; the picture rides above it in an overlay, where it
    /// is free to overflow and be clipped. `.frame(maxWidth: .infinity)` looks
    /// like it would do the same job and does not: it grows to whatever the
    /// child reports, so a 16:9 cover took the clip out to 164 pt with it.
    private func artwork(for track: MediaController.Track) -> some View {
        let metrics = Theme.artworkMetrics(isOpen: true)
        return Color.clear
            .overlay {
                if let image = media.artwork {
                    // No `.transition(.opacity)` here any more. This view is one
                    // end of a travelling object, and a travelling object that
                    // fades while it travels is the crossfade the morph was
                    // added to replace. The album-to-album crossfade it used to
                    // spell out is the default transition anyway, under the same
                    // `Theme.artworkAnimation` below.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if artworkWaitExpired {
                    // Quiet placeholder, not a shimmer: the wait is over and the
                    // cover is not coming for this track. The 132 pt well at
                    // white 0.08 with the note at 35 pt (spec §4.7) — never a
                    // stretched app icon.
                    MissingCoverWell(cornerRadius: metrics.cornerRadius)
                        .transition(.opacity)
                } else {
                    SkeletonBox(cornerRadius: metrics.cornerRadius)
                }
            }
        .task(id: track.key) {
            artworkWaitExpired = false
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            artworkWaitExpired = true
        }
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        // Paused, the cover is 0.8 of itself (spec §4.2). A colour multiply, not
        // `.brightness`, which is additive and lifts the black of a dark cover
        // towards grey — the island's own paused dim learnt that on 2026-10-15.
        .colorMultiply(media.isPlaying ? .white : Color(white: Theme.playerPausedCoverBrightness))
        .animation(Theme.contentAnimation, value: media.isPlaying)
        // The same shape again, this time for the pointer. `clipShape` hides
        // the overflow but does not stop it being touched, and `.fill` on a
        // cover that is not square overflows a long way: a 16:9 thumbnail —
        // what a video in a browser tab publishes — comes out 235 pt wide in
        // this 132 pt box, so 51 pt of invisible picture hangs over each side.
        // The left side is the tab rail, and the four icons behind that
        // overhang stopped answering the pointer (#22).
        .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.coverEdge, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .morph(NotchContentView.MorphID.artwork, in: morph)
        // Outside the morph, so the pane's layout keeps reserving 132 pt no
        // matter where the cover is on its way to. Inside it, the frame would
        // be the thing refusing the pill's size.
        .frame(width: metrics.side, height: metrics.side)
        .animation(Theme.artworkAnimation, value: media.artwork)
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    /// The progress row (spec §4.1, §4.6): the scrubber, or — for a stream with
    /// no length — the LIVE mark and a static track. A scrubber with no length
    /// is a control that reads 0:00 / 0:00, refuses to be dragged, and looks
    /// broken rather than absent.
    @ViewBuilder
    private var progressRow: some View {
        if media.duration > 0 {
            scrubber
        } else {
            liveRow
        }
    }

    /// `Music-Live-Stream`: LIVE at 9 pt bold with 0.4 of tracking, white on the
    /// accent, radius 3 and 4 pt of padding each side, then a full-width track
    /// at the surface's grey. No times, and nothing to drag.
    private var liveRow: some View {
        HStack(spacing: 6) {
            // A mark, not a line of text: it is fitted to the 12 pt row the
            // scrubber occupies, which is why it is the spec's 9 pt and not a
            // role (the smallest role is the 10 pt caption floor).
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(height: 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            Capsule()
                .fill(Theme.surface)
                .frame(height: 4)
        }
        .frame(height: 12)
        .accessibilityElement(children: .combine)
    }

    /// The elapsed and remaining labels' widths: 26 and 30 for a song, wider
    /// for an hour-long one whose times carry another digit (spec §4.1).
    static func timeWidths(duration: TimeInterval) -> (elapsed: CGFloat, remaining: CGFloat) {
        duration >= 3600 ? (52, 52) : (26, 30)
    }

    private var scrubber: some View {
        let widths = Self.timeWidths(duration: media.duration)
        return HStack(spacing: 6) {
            // While the pointer is on the bar this reads the time *under the
            // pointer*, not the time playing — the same trick every scrubber
            // worth using does, and it replaces the floating bubble that used
            // to cover the lyric line above the bar.
            // The time playing reads `labelPosition`, which never steps back a
            // second for a small correction; the preview reads the pointer.
            Text(formatTime(previewFraction.map { $0 * media.duration }
                            ?? min(media.labelPosition, media.duration)))
                .foregroundStyle(previewFraction == nil ? Theme.secondary : Color.white.opacity(0.9))
                .frame(width: widths.elapsed, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    // Deliberately unanimated: a seek has to land under the
                    // cursor at once. Smoothness comes from the tick rate
                    // instead, which keeps each step well under a pixel.
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .offset(x: min(max(filled - 5.5, 0), width - 11))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .frame(maxHeight: .infinity)
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
                    scrubWidth = width
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
                            // Seek first: clearing `scrubbing` beforehand would
                            // drop the bar back to the old position for a frame
                            // before the new one lands.
                            if DebugTrail.openLyrics {
                                DebugTrail.note(String(format: "SCRUB to=%.2f", media.duration * target))
                            }
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.contentAnimation, value: scrubHover)
            }
            // 22 pt to grab, 12 pt to lay out (F-014). The strip sits at the
            // top edge of the screen, and 12 pt there was a target a seek had
            // to be aimed at; a near miss landed on nothing. The drawn bar is
            // centred in the strip either way, and the negative padding gives
            // the extra 10 pt back to the column, so the lines above and the
            // transport below stay exactly where the board put them.
            .frame(height: 22)
            // A capsule with a drag gesture is nothing at all to assistive
            // tech; see `playbackPositionAccessibility` for why it is a slider.
            .playbackPositionAccessibility(
                shown: progress * media.duration,
                duration: media.duration,
                position: { media.position },
                seek: { media.seek(to: $0) }
            )
            .padding(.vertical, -5)

            // What is left, as the lock card's rail reads it and the board
            // draws it: "-1:09". The old row showed the length, which is the
            // question a player answers once; how long until this is over is
            // the one a scrubber is asked all the time. It follows the pointer
            // preview too, so the two labels agree about where the bar is.
            Text("-" + formatTime(max(0, media.duration - (previewFraction.map { $0 * media.duration }
                                                                ?? min(media.labelPosition, media.duration)))))
                .frame(width: widths.remaining, alignment: .trailing)
        }
        .font(Theme.TypeRole.caption.font(weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.secondary)
    }

    // MARK: - Controls

    /// Shuffle and Repeat flank the transport (spec §4.1, §4.4): shown only when
    /// the source reports them, and the slots are held when it does not, so the
    /// transport keeps its place whichever track is next.
    @ViewBuilder
    private func modeButtons(layout: PlayerLayout) -> some View {
        Group {
            if let shuffle = media.shuffleEnabled {
                // Off: a tertiary 12 pt glyph. On: white, with a 3 pt dot 2 pt
                // below it — `ModeToggle`'s own grammar, which the lock card's
                // sibling shares.
                ModeToggle(symbol: "shuffle", isOn: shuffle, size: 24, glyphSize: 12) { media.toggleShuffle() }
                    .help(localized("Shuffle"))
                    .accessibilityLabel(localized("Shuffle"))
                    .accessibilityValue(shuffle ? localized("On") : localized("Off"))
            }
        }
        .placed(layout.inPane(layout.shuffle), alignment: .center)
        Group {
            if let mode = media.repeatMode {
                // `repeat.1` is the system's own "1" at the glyph's top right,
                // which the board draws by hand because its sprite has no such
                // glyph.
                ModeToggle(
                    symbol: mode == .one ? "repeat.1" : "repeat",
                    isOn: mode != .off, size: 24, glyphSize: 12,
                    reduceMotion: reduceMotion
                ) { media.cycleRepeat() }
                    .help(localized("Repeat: %@", repeatValueLabel(mode)))
                    .accessibilityLabel(localized("Repeat"))
                    .accessibilityValue(repeatValueLabel(mode))
            }
        }
        .placed(layout.inPane(layout.repeatButton), alignment: .center)
    }

    /// Previous 16 pt, play/pause 20 pt, next 16 pt, in 28 pt targets spread over
    /// the 100 pt the board gives them.
    private var transport: some View {
        HStack(spacing: 0) {
            Button { media.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: Theme.playerSkipGlyphSize, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: Theme.playerTransportTarget))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Previous Track"))
            .accessibilityLabel(localized("Previous Track"))
            Spacer(minLength: 0)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: Theme.playerPlayGlyphSize, weight: .medium))
                    // The glyph is replaced, not swapped. A hard cut on the one
                    // control the eye is already resting on is the most visible
                    // non-native moment in the app; `.replace` is what every
                    // Apple transport control does. The play state changes
                    // outside any animation, so the swap brings its own.
                    .symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)
            }
            .buttonStyle(TransportGlyphStyle(size: Theme.playerTransportTarget))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Spacer(minLength: 0)
            Button { media.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: Theme.playerSkipGlyphSize, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: Theme.playerTransportTarget))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Next Track"))
            .accessibilityLabel(localized("Next Track"))
        }
        .animation(Theme.contentAnimation, value: media.canSkip)
    }

    /// The Lyrics door at the trailing edge (spec §4.1): `quote.bubble`, 14 pt in
    /// a 26 pt target. For now it opens the existing lyrics page; the lyric
    /// column replaces that destination in the next task, and this is also where
    /// the open state (`quote.bubble.fill` on the selected fill) will be drawn.
    private var lyricsButton: some View {
        Button { showingLyrics.wrappedValue = true } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Lyrics"))
        .accessibilityLabel(localized("Lyrics"))
        .accessibilityHint(localized("Opens the full lyrics"))
    }

    private func repeatValueLabel(_ mode: PlayerBridge.RepeatMode) -> String {
        switch mode {
        case .off: return localized("Off")
        case .all: return localized("All Tracks")
        case .one: return localized("This Track")
        }
    }

    // MARK: - The lyric band

    /// The band: the line being sung — 13 pt bold, swept, at full white — and the
    /// line after it, 13 pt semibold at the ramp's floor (spec §4.3). Both turn
    /// with `captionTurnOut`/`captionTurnIn` and read ahead exactly as the
    /// caption they replace did (`captionResolution` →
    /// `LyricSweep.readingMoment`, "Show next line early"), and clicking the
    /// sung line opens the lyrics page as the caption did. Paused, the sung line
    /// is 0.7 of itself (spec §4.2).
    @ViewBuilder
    private func lyricBand(for track: MediaController.Track, layout: PlayerLayout) -> some View {
        if case .synced(let lines) = lyrics.state {
            let wordTimingEnabled = LyricsPresentation.usesWordTiming(
                lyrics.timingGranularity,
                precisionMeasured: media.precisionSync,
                wordKaraokeEnabled: lyrics.wordKaraokeEnabled
            )
            if let shown = Self.captionResolution(lines: lines, inputs: LyricInputs(
                position: media.position,
                precisionSync: media.precisionSync,
                userOffset: lyrics.userOffset,
                trackOffset: lyrics.trackOffset,
                wordTiming: wordTimingEnabled
            ), readAhead: lyrics.readAhead) {
                // The row shown: the line being sung, or the opening line
                // waiting through the intro.
                let index = shown.centre
                let line = lines[index]
                let nextIndex = Self.nextBandIndex(after: index, count: lines.count)
                // Each line has a slot of its own, clipped, so a line turning out
                // never crosses the line above or below it, and a one-line song
                // leaves the second slot empty rather than collapsing the first.
                // `Color.clear` underneath, not a frame on the line alone: a
                // `@ViewBuilder` whose `if` fails produces no view at all, and a
                // fixed frame on nothing reserves nothing.
                Button { showingLyrics.wrappedValue = true } label: {
                    ZStack(alignment: .leading) {
                        Color.clear
                        KaraokeText(
                            text: line.text,
                            // Where the voice stands inside this line, 0...1,
                            // and 0 for a credit or a line the voice has not
                            // reached: a filled sweep across "Produced by", or
                            // across the opening line during the intro, says
                            // the voice is there, which it is not.
                            fraction: shown.fraction,
                            // And the same sweep read on every frame from the
                            // running clock while the voice is in a word-timed
                            // line, so the edge is not a tick behind it. Never
                            // for the opening line waiting through an intro.
                            clock: shown.current.flatMap { current in
                                LyricSweep.liveFraction(
                                    line: line, end: LyricSweep.end(of: current, in: lines),
                                    wordTiming: wordTimingEnabled,
                                    clock: LyricSweep.frameClock(media: media, lead: LyricSweep.lead(
                                        precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                                        trackOffset: lyrics.trackOffset
                                    ))
                                )
                            },
                            reduceMotion: reduceMotion,
                            accent: .white,
                            font: Theme.TypeRole.subhead.font(weight: .bold),
                            // At the subhead size SF sits at its neutral
                            // tracking; matched to the next line below so the
                            // pair reads as one band.
                            tracking: Theme.tracking(forSize: Theme.TypeRole.subhead.size)
                        )
                        .italic(line.isCredit)
                        // Keyed so a line change is a change of line — not a
                        // morph glyph-by-glyph in place — and the change is a
                        // turn, not a crossfade: see `AnyTransition.lyricLine`.
                        // By row, not by timestamp: two lines stamped at one
                        // moment (a bilingual LRC) shared a key, so the second
                        // replaced the first in place with no turn at all.
                        .id(index)
                        .transition(.lyricLine(reduceMotion: reduceMotion))
                    }
                    .frame(height: Self.captionHeight)
                    .clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .opacity(media.isPlaying ? 1 : Theme.playerPausedLyricOpacity)
                // On the lyric spring, like the page and the row: the song
                // carries this motion. The line turn itself does not ride it:
                // `AnyTransition.lyricLine` attaches its own out-fast, in-behind
                // pair (`Theme.captionTurnOut`/`In`), because on this one spring
                // the old and new lines crossed at once and smeared over each
                // other (H-014).
                .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: index)
                .animation(Theme.contentAnimation, value: media.isPlaying)
                .accessibilityLabel(localized("Lyrics"))
                .accessibilityValue(line.text)
                .accessibilityHint(localized("Opens the full lyrics"))
                .placed(layout.inPane(layout.sungLine))
                // One band per song. A new song's first line arrives with its
                // title, in the column's crossfade — not on the line-turn
                // spring, which carried the last song's line out under the new
                // title for up to a fifth of a second (filmed on 2026-09-21).
                // Lines within a song still turn.
                .id(track.key)
                .transition(.opacity)

                if let nextIndex {
                    ZStack(alignment: .leading) {
                        Color.clear
                        Text(lines[nextIndex].text)
                            .islandFont(.subhead, weight: .semibold)
                            .foregroundStyle(Theme.lyricBandNext)
                            .italic(lines[nextIndex].isCredit)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(nextIndex)
                            .transition(.lyricLine(reduceMotion: reduceMotion))
                    }
                    .frame(height: Self.captionHeight)
                    .clipped()
                    .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: index)
                    // The sung line says it for both: the next line is a preview
                    // of what a screen reader gets in a moment anyway.
                    .accessibilityHidden(true)
                    .placed(layout.inPane(layout.nextLine))
                    .id(track.key)
                    .transition(.opacity)
                }
            }
        }
    }

    /// What the caption draws for one reading of the clock, or nil when there
    /// are no lines to show. Its row is the line being sung, or the line the
    /// voice reaches next while it has not reached any — the opening line,
    /// unswept — through the same `LyricSweep.resolve` as the stage and the
    /// lock card. The lyric lab calls this function rather than a copy of the
    /// caption's arithmetic.
    ///
    /// `readAhead` is "Show next line early" (`LyricSweep.readingMoment`): the
    /// band is the one surface that holds a single sung line, so it is the one
    /// that turns to the next line a beat before the voice reaches it. The
    /// default is no lead, which the Lyric Delay preview relies on.
    static func captionResolution(
        lines: [LyricsStore.Line], inputs: LyricInputs, readAhead: LyricReadAhead = .off
    ) -> LyricResolution? {
        // With no lines there is nothing to caption. Otherwise it is the
        // moment's centre — the row the stage and the card centre on — which
        // is why the view draws `centre`. That includes the outro after the
        // last line's end, where nothing is sung and nothing is coming: the
        // guard used to ask for a current or an upcoming line, which until
        // line ends existed was only ever false for an empty lyric, and in
        // the outro it would have swapped the last line for "Finding lyrics…".
        guard !lines.isEmpty else { return nil }
        return LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: readAhead)
    }

    // MARK: - Nothing playing (spec §4.8)

    /// What the empty tab says, apart from any drawing, so which status wins
    /// is something a test can read.
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

        /// The line under the headline (spec §4.8). Every state has one now:
        /// the empty player says what to do, what is wrong, or what it chose
        /// not to show.
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
    }

    /// The empty tab used to say "Nothing is playing." over a YouTube video
    /// that was audibly playing (J-007): Music Only filtered it, which is the
    /// recorded design, but `MediaController` already knew — it publishes
    /// `otherMediaIsPlaying` to fold the pill — but the pane never asked. The
    /// reader being down wins over the filter because it explains more: with
    /// the helper gone, the filter is not what hides a browser. And the
    /// filter's own switch is checked, not just the controller's flag, which
    /// is recomputed only on the next report and so trails the switch.
    static func emptyStateMessage(
        fallback: NowPlayingRouteFailure?, otherMediaPlaying: Bool, musicOnly: Bool
    ) -> EmptyStateMessage {
        if fallback != nil { return .readerDown }
        if otherMediaPlaying && musicOnly { return .hiddenByMusicOnly }
        return .nothingPlaying
    }

    /// The empty player keeps the playing layout's frame: a 132 pt well where the
    /// cover goes, and a status, one line of why, and the remedy. No transport —
    /// disabled controls under an empty state were a second, dead message.
    private var emptyState: some View {
        let message = Self.emptyStateMessage(
            fallback: media.fallbackReason,
            otherMediaPlaying: media.otherMediaIsPlaying,
            musicOnly: media.musicOnly()
        )
        let frames = PlayerLayout.emptyFrames(for: message)
        let leading = PlayerLayout.columnLeading - PlayerLayout.paneLeading
        return ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: Theme.artworkMetrics(isOpen: true).cornerRadius, style: .continuous)
                .fill(Theme.emptyWell)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.artworkMetrics(isOpen: true).cornerRadius, style: .continuous)
                        .strokeBorder(Theme.emptyWellEdge, lineWidth: 0.5)
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: Theme.emptyNoteSize))
                        .foregroundStyle(Theme.emptyWellNote)
                )
                .placed(PlayerLayout.inPane(PlayerLayout.emptyWell, headerHeight: headerHeight))
                .accessibilityHidden(true)

            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing, nothing could be read, or something
            // is playing that the island chose not to show.
            Text(message.headline)
                .islandFont(frames.titleSize, weight: .semibold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: PlayerLayout.EmptyFrames.textWidth, alignment: .topLeading)
                .offset(x: leading, y: frames.titleY - headerHeight)
            Text(message.caption)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: PlayerLayout.EmptyFrames.textWidth, alignment: .topLeading)
                .offset(x: leading, y: frames.bodyY - headerHeight)
            // And an affordance, because a dead end teaches people not to
            // open the tab. Status first, then one remedy: when the filter is
            // what hides a playing source, the remedy is the switch, not a
            // player to open — a person watching YouTube does not need
            // Spotify launched. It opens Settings at the switch rather than
            // flipping it from here, because a status line has no room to say
            // what else Music Only decides.
            HStack(spacing: PlayerLayout.EmptyFrames.buttonSpacing) {
                if message.offersSettings {
                    Button(action: openMusicOnlySetting) {
                        Text(localized("Open Settings"))
                    }
                    .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: PlayerLayout.EmptyFrames.buttonHeight))
                } else {
                    // One button per player that is actually installed.
                    ForEach(PlayerApp.allCases.filter(Self.isInstalled), id: \.rawValue) { app in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: Self.applicationPath(for: app) ?? ""))
                        } label: {
                            Text(localized("Open %@", app.displayName))
                        }
                        .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: PlayerLayout.EmptyFrames.buttonHeight))
                    }
                }
            }
            .offset(x: leading, y: frames.buttonsY - headerHeight)
            if let footnote = message.footnote, let footerY = frames.footerY {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .islandFont(.body, weight: .regular)
                    Text(footnote)
                        .islandFont(.body, weight: .regular)
                }
                .foregroundStyle(Theme.tertiary)
                .offset(x: leading, y: footerY - headerHeight)
            }
        }
    }

    private static func isInstalled(_ app: PlayerApp) -> Bool {
        applicationPath(for: app) != nil
    }

    private static func applicationPath(for app: PlayerApp) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path
    }
}

// MARK: - A cover that is not coming

/// The well that stands where a missing cover goes (spec §4.7): white 0.08 with a
/// `music.note` at 35 pt in the quaternary white. Its own view so a test can draw
/// it without waiting out the 2.5 s the pane gives a cover to arrive.
struct MissingCoverWell: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.coverMissingWell)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: Theme.playerCoverNoteSize))
                    .foregroundStyle(Theme.quaternary)
            )
    }
}

// MARK: - Placement

private extension View {
    /// Puts the view in `rect`, in the pane's coordinates: sized to it, aligned
    /// to its leading edge, and offset to its corner. The frames come from
    /// `PlayerLayout`, so nothing here knows a number.
    func placed(_ rect: CGRect, alignment: Alignment = .leading) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - Volume and Output

/// The player's volume bar: the shared slider in the player's dress, with a
/// model of its own over the pane's `AudioWatch`. Absent for a device with no
/// volume to give, rather than a bar that moves and changes nothing.
private struct PlayerVolumeSlider: View {
    @StateObject private var model: VolumeSliderModel
    let trackKey: String?

    init(audio: AudioWatch, trackKey: String?) {
        _model = StateObject(wrappedValue: VolumeSliderModel(audio: audio))
        self.trackKey = trackKey
    }

    var body: some View {
        Group {
            if model.volume != nil {
                SystemVolumeSlider(model: model, look: .player)
            }
        }
        // A drag a new song cut short lets go here (K-017), as on the lock card.
        .onChange(of: trackKey) { _, _ in model.endForTrackChange() }
    }
}

/// The Output button: `airplay.audio` in a 26 pt target, opening the NSMenu
/// of devices under it. Nothing is chosen, and nothing changes on the Mac,
/// until a row is picked.
private struct PlayerOutputButton: View {
    @ObservedObject var audio: AudioWatch
    let includesVolume: Bool
    @State private var presenter: OutputMenuPresenter

    init(audio: AudioWatch, includesVolume: Bool) {
        self.audio = audio
        self.includesVolume = includesVolume
        _presenter = State(initialValue: OutputMenuPresenter(controller: OutputMenuController(audio: audio)))
    }

    var body: some View {
        Button { presenter.present(includesVolume: includesVolume) } label: {
            Image(systemName: "airplay.audio")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .background(OutputMenuAnchor(presenter: presenter))
        .help(localized("Sound Output"))
        .accessibilityLabel(localized("Sound Output"))
        // Where the sound goes now, which the glyph cannot say.
        .accessibilityValue(LockScreenCard.outputName(outputs: audio.outputs, current: audio.current) ?? "")
    }
}

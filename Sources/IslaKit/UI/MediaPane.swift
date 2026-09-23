import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    var localLookup: LocalLyricsLookup? = nil
    var retryLyrics: () -> Void = {}
    var importLocalFile: () -> Void = {}
    var selectLocalCandidate: (LocalLyricsCandidate) -> Void = { _ in }
    var removeLocalBinding: () -> Void = {}
    var localLibrary: LocalLyricsLibrary?
    var currentLocalTrackIdentity: () -> LocalTrackIdentity? = { nil }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var editingCandidate: LocalLyricsCandidate?
    /// Hover on the caption, which surfaces its chevron.
    @State private var captionHover = false

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 122

    /// The caption's slot, kept whether or not there is a word to put in it.
    ///
    /// The line used to be a conditional view, so a track with no lyrics — or one
    /// whose words had not arrived yet — laid its scrubber out somewhere else
    /// entirely, and every arrival and departure of a lyric moved the controls
    /// under a pointer already travelling towards them. An empty slot costs 17 pt
    /// of nothing; a moving target costs the click.
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
                        importLocalFile: importLocalFile,
                        selectLocalCandidate: selectLocalCandidate,
                        removeLocalBinding: removeLocalBinding,
                        editLocalLyrics: { candidate in
                            guard localLibrary != nil else { return }
                            editingCandidate = candidate
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
                if DebugTrail.openLyrics {
                    DebugTrail.note("MediaPane track=\(track.title) showingLyrics=\(showingLyrics.wrappedValue)")
                }
            }
            .sheet(item: $editingCandidate) { candidate in
                if let localLibrary {
                    LocalLyricsEditorView(
                        document: candidate.document,
                        editor: LocalLyricsEditor(library: localLibrary),
                        binding: currentLocalTrackIdentity(),
                        onSaved: { _ in editingCandidate = nil },
                        onDismiss: { editingCandidate = nil }
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

    private func player(for track: MediaController.Track) -> some View {
        HStack(spacing: 18) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .islandFont(.title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 3)

                    // The same order the lock card reads in: who is playing,
                    // what is being sung, where the song is, and the transport
                    // last. Two surfaces showing the same track in a different
                    // sequence is the kind of difference nobody can name and
                    // everybody feels.
                    // `Color.clear` underneath, not a frame on the caption
                    // alone. A `@ViewBuilder` whose `if` fails produces no view
                    // at all, and a fixed frame on nothing reserves nothing —
                    // measured: the scrubber still moved 10 px. Something has
                    // to be in the slot for the slot to exist.
                    ZStack(alignment: .leading) {
                        Color.clear
                        lyricsLine
                            // One caption per song. A new song's first line
                            // arrives with its title, in the column's
                            // crossfade — not on the line-turn spring, which
                            // carried the last song's line out under the new
                            // title for up to a fifth of a second (filmed on
                            // 2026-09-21). Lines within a song still turn.
                            .id(track.key)
                            .transition(.opacity)
                    }
                    .frame(height: Self.captionHeight)
                    // The line turn travels inside the slot and nowhere else:
                    // a line lifting out must not cross the artist above it.
                    .clipped()
                    .padding(.top, 4)
                    Spacer(minLength: 6)
                    // A live stream has no duration, and a scrubber with no
                    // length is a control that reads 0:00 / 0:00, refuses to
                    // be dragged, and looks broken rather than absent.
                    if media.duration > 0 {
                        scrubber
                    }
                    Spacer(minLength: 4)
                    controls
                }
                .frame(height: blockHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Title and artist arrive together, so the whole column can cross-
        // fade as one unit when the track changes.
        .animation(Theme.artworkAnimation, value: track.key)
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
    /// described twice is how it came to be drawn twice.
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
                    // cover is not coming for this track.
                    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(
                            Image(systemName: "music.note")
                                .islandFont(.hero, weight: .light)
                                .foregroundStyle(Theme.tertiary)
                        )
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
        // The same shape again, this time for the pointer. `clipShape` hides
        // the overflow but does not stop it being touched, and `.fill` on a
        // cover that is not square overflows a long way: a 16:9 thumbnail —
        // what a video in a browser tab publishes — comes out 211 pt wide in
        // this 118 pt box, so 46 pt of invisible picture hangs over each side.
        // The left side is the tab rail, and the four icons behind that
        // overhang stopped answering the pointer (#22).
        .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .morph(NotchContentView.MorphID.artwork, in: morph)
        // Outside the morph, so the pane's layout keeps reserving 118 pt no
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

    private var scrubber: some View {
        HStack(spacing: 10) {
            // While the pointer is on the bar this reads the time *under the
            // pointer*, not the time playing — the same trick every scrubber
            // worth using does, and it replaces the floating bubble that used
            // to cover the lyric line above the bar.
            // The time playing reads `labelPosition`, which never steps back a
            // second for a small correction; the preview reads the pointer.
            Text(formatTime(previewFraction.map { $0 * media.duration }
                            ?? min(media.labelPosition, media.duration)))
                .foregroundStyle(previewFraction == nil ? Theme.tertiary : Color.white.opacity(0.9))
                .frame(width: media.duration >= 3600 ? 52 : 32, alignment: .leading)

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
            .frame(height: 14)
            // A capsule with a drag gesture is nothing at all to assistive
            // tech. Declared as one adjustable element instead, seeking in
            // five-percent steps, so the position can be both heard and moved
            // without the pointer.
            .accessibilityElement()
            .accessibilityLabel(localized("Playback Position"))
            .accessibilityValue(
                localized(
                    "%@ of %@",
                    formatTime(progress * media.duration),
                    formatTime(media.duration)
                )
            )
            .accessibilityAdjustableAction { direction in
                let step = media.duration * 0.05
                switch direction {
                case .increment: media.seek(to: media.position + step)
                case .decrement: media.seek(to: media.position - step)
                @unknown default: break
                }
            }

            Text(formatTime(media.duration))
                .frame(width: media.duration >= 3600 ? 52 : 32, alignment: .trailing)
        }
        .font(Theme.TypeRole.caption.font().monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    /// The transport row: shuffle, previous, play/pause, next, repeat.
    @ViewBuilder
    private var controls: some View {
        // Spread edge to edge, the same five-slot grammar the lock card uses:
        // the modes anchor the ends, the transport takes the middle, and the
        // row keeps its shape whatever the player can be asked. A track with
        // no shuffle to offer holds the space rather than letting everything
        // else slide sideways when the next one does.
        HStack(spacing: 0) {
            Group {
                if let shuffle = media.shuffleEnabled {
                    ModeToggle(symbol: "shuffle", isOn: shuffle) { media.toggleShuffle() }
                        .help(localized("Shuffle"))
                        .accessibilityLabel(localized("Shuffle"))
                        .accessibilityValue(shuffle ? localized("On") : localized("Off"))
                }
            }
            .frame(width: 26)
            Spacer(minLength: 0)
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").islandFont(.title, weight: .medium)
            }
            .buttonStyle(TransportGlyphStyle(size: 30))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Previous Track"))
            .accessibilityLabel(localized("Previous Track"))
            Spacer(minLength: 0)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .islandFont(.display)
                    // The glyph is replaced, not swapped. A hard cut on the one
                    // control the eye is already resting on is the most visible
                    // non-native moment in the app; `.replace` is what every
                    // Apple transport control does.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Spacer(minLength: 0)
            Button { media.next() } label: {
                Image(systemName: "forward.fill").islandFont(.title, weight: .medium)
            }
            .buttonStyle(TransportGlyphStyle(size: 30))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Next Track"))
            .accessibilityLabel(localized("Next Track"))
            Spacer(minLength: 0)
            Group {
                if let mode = media.repeatMode {
                    ModeToggle(
                        symbol: mode == .one ? "repeat.1" : "repeat",
                        isOn: mode != .off,
                        reduceMotion: reduceMotion
                    ) { media.cycleRepeat() }
                        .help(localized("Repeat"))
                        .accessibilityLabel(localized("Repeat"))
                        .accessibilityValue(repeatValueLabel(mode))
                }
            }
            .frame(width: 26)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.contentAnimation, value: media.canSkip)
        .animation(Theme.contentAnimation, value: media.shuffleEnabled == nil)
        .animation(Theme.contentAnimation, value: media.repeatMode == nil)
    }

    private func repeatValueLabel(_ mode: PlayerBridge.RepeatMode) -> String {
        switch mode {
        case .off: return localized("Off")
        case .all: return localized("All Tracks")
        case .one: return localized("This Track")
        }
    }

    /// One line, sung now, where the eye already is — with the sung part of it
    /// brightening as the voice moves through. No scrolling wall of text: the
    /// pane is 122pt of album art and transport, and the lyric is a caption to
    /// the music, not a document.
    @ViewBuilder
    private var lyricsLine: some View {
        if case .ready = lyrics.availability,
           case .synced(let lines) = lyrics.state {
            let at = LyricSweep.position(
                media.position,
                precisionSync: media.precisionSync,
                userOffset: lyrics.userOffset,
                trackOffset: lyrics.trackOffset
            )
            if let shown = LyricSweep.displayed(lines: lines, at: at) {
                let line = shown.line
                let wordTimingEnabled = LyricsPresentation.usesWordTiming(
                    lyrics.timingGranularity,
                    precisionMeasured: media.precisionSync,
                    wordKaraokeEnabled: lyrics.wordKaraokeEnabled
                )
                // Where the voice stands inside this line, 0...1. The catalogue
                // carries line timestamps, not word ones, so within a line the
                // sweep is linear time — even pacing, which is what singing
                // mostly is. The end of the last line borrows a spoken-line
                // length rather than running to the end of the track.
                let end = shown.end
                // The caption is the door to the stage: click it and the pane
                // becomes the full scrolling lyrics. A chevron surfaces on
                // hover so the door reads as one — a bare line of text gives
                // no hint that it goes anywhere.
                Button { showingLyrics.wrappedValue = true } label: {
                    HStack(spacing: 5) {
                        KaraokeText(
                            text: line.text,
                            // A credit is not being sung, so it is not swept:
                            // a filled sweep across "Produced by" says the
                            // voice is there, which it is not.
                            fraction: line.isCredit || !shown.swept
                                ? 0
                                : wordTimingEnabled
                                    ? LyricSweep.fraction(line: line, at: at, end: end)
                                    : 1,
                            reduceMotion: reduceMotion,
                            // The caption sits at the body size, where SF opens tracking
                            // up slightly rather than tightening it.
                            tracking: Theme.tracking(forSize: Theme.TypeRole.body.size)
                        )
                        .italic(line.isCredit)
                        // Keyed so a line change is a change of line — not a
                        // morph glyph-by-glyph in place — and the change is a
                        // turn, not a crossfade: see `AnyTransition.lyricLine`.
                        .id(line.at)
                        .transition(.lyricLine(reduceMotion: reduceMotion))
                        Image(systemName: "chevron.right")
                            // A glyph fitted to its row, not type: it sizes
                            // the chevron against the caption's cap height,
                            // and the caption floor has nothing to say about it.
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                            // Always in the row, faded rather than inserted. A
                            // chevron that arrived on hover took its width from
                            // the lyric beside it, so the line re-truncated
                            // under the pointer that had just reached it.
                            .opacity(captionHover ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .onHover { captionHover = $0 }
                // On the lyric spring, like the page and the row: the song
                // carries this motion, so it is allowed the momentum the
                // 0.16 s content ease was refusing it.
                .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: line.at)
                .animation(Theme.contentAnimation, value: captionHover)
                .accessibilityLabel(localized("Lyrics"))
                .accessibilityValue(line.text)
                .accessibilityHint(localized("Opens the full lyrics"))
            } else {
                compactLyricsStatus
            }
        } else {
            compactLyricsStatus
        }
    }

    private var compactLyricsStatus: some View {
        Button { showingLyrics.wrappedValue = true } label: {
            HStack(spacing: 5) {
                if case .findingLocalLyrics = lyrics.availability {
                    ProgressView().controlSize(.mini).tint(Theme.tertiary)
                }
                Text(LyricsPresentation.compactCaption(
                    for: lyrics.availability, currentLine: nil, localLookup: localLookup,
                    onlineEnabled: NotchViewModel.onlineLyricsEnabled
                ))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .opacity(captionHover ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .onHover { captionHover = $0 }
        .animation(Theme.contentAnimation, value: captionHover)
        .accessibilityLabel(localized("Lyrics"))
        .accessibilityValue(LyricsPresentation.compactCaption(
            for: lyrics.availability, currentLine: nil, localLookup: localLookup,
            onlineEnabled: NotchViewModel.onlineLyricsEnabled
        ))
        .accessibilityHint(localized("Opens the full lyrics"))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .islandFont(.display, weight: .light)
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text(localized("Nothing is playing."))
                .islandFont(.subhead)
                .foregroundStyle(Theme.secondary)
            // Unless something is and the reader cannot see it. Without this
            // line a browser could play under a pane that said nothing was;
            // Settings → Music says why and offers Try Again.
            if media.fallbackReason != nil {
                Text(localized("Only Music and Spotify can be seen right now."))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
            }
            // And an affordance, because a dead end teaches people not to
            // open the tab. One button per player that is actually installed.
            HStack(spacing: 8) {
                ForEach(PlayerApp.allCases.filter(Self.isInstalled), id: \.rawValue) { app in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Self.applicationPath(for: app) ?? ""))
                    } label: {
                        Text(localized("Open %@", app.displayName))
                            .islandFont(.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(PanelButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func isInstalled(_ app: PlayerApp) -> Bool {
        applicationPath(for: app) != nil
    }

    private static func applicationPath(for app: PlayerApp) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path
    }
}

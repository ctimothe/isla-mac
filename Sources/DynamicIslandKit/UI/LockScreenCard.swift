import CoreAudio
import SwiftUI

/// The media player shown while the Mac is locked.
///
/// Laid out the way the system's own lock-screen player is: the track across
/// the top, one changing middle, the transport under it, and a rail of
/// secondary actions at the foot. Three middles — the scrubber, the words, the
/// output devices — and the two glyphs in the foot rail are what swap between
/// them.
///
/// **The card is one fixed size in every state.** It has its own window above
/// the login shield, and that window is never resized: the window server
/// snapshots windows across a lock transition, and a snapshot taken at one size
/// stretched into another is precisely the half-scale off-centre card this
/// window was created to end. So the states change what is drawn, never how
/// much room it takes.
///
/// Interactive, deliberately: the transport, the scrubber, each lyric line and
/// each output row answer clicks, and the window's hit region is exactly this
/// card — the rest of the lock screen still belongs to the password field.
struct LockScreenCard: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject private var spotify = SpotifyAccount.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which middle is showing. One value rather than a pair of bools, so two
    /// panes can never be open at once — which is what a `showingOutputs` and a
    /// `showingLyrics` flag will eventually do to each other.
    enum Pane: String, CaseIterable {
        case player, lyrics, output
    }

    @State private var pane: Pane

    /// Which pane the card opens on. Always `.player` in the app; the parameter
    /// exists so a render can photograph the other two without a click.
    init(media: MediaController, lyrics: LyricsStore, initialPane: Pane = .player) {
        self.media = media
        self.lyrics = lyrics
        _pane = State(initialValue: initialPane)
    }

    @State private var palette: ArtworkPalette?
    @State private var scrubbing: Double?
    @State private var outputs: [AudioOutputs.Output] = []
    @State private var currentOutput: AudioDeviceID?
    @State private var volume: Float?
    @State private var draggingVolume: Float?

    /// Read through `@AppStorage` so changing it in Settings redraws the card
    /// while it is on screen, rather than at the next lock.
    @AppStorage(NotchViewModel.lockCardStyleKey) private var styleRaw = NotchViewModel.LockCardStyle.glass.rawValue

    private var style: NotchViewModel.LockCardStyle {
        NotchViewModel.LockCardStyle(rawValue: styleRaw) ?? .glass
    }

    static let size = CGSize(width: 460, height: 300)

    /// How many lyric lines the middle shows. Odd, so the line being sung sits
    /// in the centre with the same amount of song either side of it.
    static let visibleLyricLines = 5

    private var accent: Color {
        guard let palette, palette.isVivid else { return .white }
        return Color(nsColor: palette.dominant)
    }

    var body: some View {
        if let track = media.track {
            VStack(spacing: 0) {
                header(track)
                Spacer(minLength: 12)
                middle
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 12)
                transport
                footer
                    .padding(.top, 10)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            // Every mark on the card carries its own shadow on glass. That is
            // how white type survives a bright wallpaper without a scrim
            // painting the wallpaper out — the system does the same on its own
            // lock screen, and it is why the clock there is readable over
            // anything.
            .shadow(color: .black.opacity(style == .glass ? 0.55 : 0), radius: 4, y: 1)
            .frame(width: Self.size.width, height: Self.size.height)
            .glassSurface(
                cornerRadius: 30,
                elevation: .card,
                tint: style == .glass ? (palette?.isVivid == true ? Color(nsColor: palette!.dominant) : nil) : nil,
                light: style == .glass ? media.artwork : nil,
                samplesBackdrop: style == .glass
            )
            .background {
                if style == .solid {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(.black.opacity(0.45))
                        }
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.38), radius: 30, y: 14)
            .environment(\.colorScheme, .dark)
            // A new song puts the card back on the player. Words and a device
            // list both belong to the track that was showing when they were
            // opened, and leaving either up across a change shows one song's
            // pane over another song's title.
            .onChange(of: track.key) { _, _ in pane = .player }
            .onAppear { readAudio() }
            .onChange(of: pane) { _, _ in readAudio() }
            .task(id: media.artwork) {
                guard let artwork = media.artwork else {
                    palette = nil
                    return
                }
                palette = await Task.detached(priority: .userInitiated) {
                    ArtworkPalette.extract(from: artwork)
                }.value
            }
            .task(id: "\(track.key)|\(media.spotifyTrackID ?? "")") {
                guard NotchViewModel.showLyricsEnabled else { return }
                lyrics.load(
                    title: track.title, artist: track.artist,
                    album: track.album, duration: media.duration,
                    spotifyID: media.spotifyTrackID
                )
            }
            .transition(.opacity)
        }
    }

    // MARK: - Header

    private func header(_ track: MediaController.Track) -> some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: pane == .player ? 18 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: pane == .player ? 14 : 12.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: pane)
    }

    /// The cover shrinks when a pane needs the room, and the card does not.
    private var artwork: some View {
        let side: CGFloat = pane == .player ? 62 : 42
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: side / 3, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        )
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side / 5.5, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            .overlay(alignment: .topTrailing) { heart.padding(3) }

            // The source badge the field overlaps on the artwork corner —
            // instant context, no text.
            if let source = media.sourceName, !source.isEmpty {
                Text(String(source.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .offset(x: 4, y: 4)
            }
        }
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: pane)
    }

    // MARK: - The three middles

    @ViewBuilder
    private var middle: some View {
        ZStack {
            switch pane {
            case .player: playerPane
            case .lyrics: lyricsPane
            case .output: outputPane
            }
        }
        .animation(reduceMotion ? nil : Theme.paneAnimation, value: pane)
        .transition(.opacity)
    }

    private var playerPane: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            seekBar
            if volume != nil { volumeBar }
            Spacer(minLength: 0)
        }
    }

    /// The words, centred on the line being sung.
    ///
    /// A fixed window of lines rather than a scroll view: the card cannot grow,
    /// and a scroller inside a surface that answers clicks above the login
    /// shield is one more thing to get wrong there. Clicking a line seeks to it,
    /// exactly as it does on the full stage.
    private var lyricsPane: some View {
        Group {
            if case .synced(let lines) = lyrics.state, !lines.isEmpty {
                let at = LyricSweep.position(
                    media.position,
                    precisionSync: media.precisionSync,
                    userOffset: lyrics.userOffset
                )
                let centre = Self.centreIndex(lines: lines, at: at)
                let window = Self.window(around: centre, count: lines.count, size: Self.visibleLyricLines)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(window, id: \.self) { index in
                        lyricRow(lines: lines, index: index, centre: centre, at: at)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(lyricsStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var lyricsStatus: String {
        guard NotchViewModel.showLyricsEnabled else { return localized("Lyrics are switched off in Settings.") }
        switch lyrics.state {
        case .loading: return localized("Looking for the words…")
        default: return localized("No words for this track.")
        }
    }

    @ViewBuilder
    private func lyricRow(
        lines: [LyricsStore.Line], index: Int, centre: Int, at: TimeInterval
    ) -> some View {
        let line = lines[index]
        let isCurrent = index == centre
        let distance = abs(index - centre)
        Button {
            media.seek(to: max(0, line.at - LyricSweep.lead(
                precisionSync: media.precisionSync, userOffset: lyrics.userOffset
            ) + 0.02))
        } label: {
            Group {
                if isCurrent {
                    let end = index + 1 < lines.count ? lines[index + 1].at : line.at + 6
                    KaraokeText(
                        text: line.text,
                        fraction: line.isCredit ? 0 : LyricSweep.fraction(line: line, at: at, end: end),
                        reduceMotion: reduceMotion,
                        accent: accent == .white ? .white : accent,
                        font: .system(size: 16, weight: .bold),
                        base: .white.opacity(0.5),
                        lineLimit: 1
                    )
                } else {
                    Text(line.text)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(distance == 1 ? 0.34 : 0.18))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .italic(line.isCredit)
        .accessibilityLabel(line.text)
        .accessibilityHint(localized("Jumps the song to this line"))
    }

    /// Where the sound goes. Every app follows the system default, so this is a
    /// real thing the card can change.
    private var outputPane: some View {
        VStack(spacing: 5) {
            if outputs.isEmpty {
                Text(localized("No output devices."))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(outputs.prefix(4)) { device in
                    outputRow(device)
                }
                if outputs.count > 4 {
                    Text(localized("+%d more in Sound Settings", outputs.count - 4))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                }
            }
        }
        // Read here as well as on the button, so the list is right however the
        // pane came to be showing — and so a device plugged in while it is open
        // appears rather than waiting for the pane to be closed and reopened.
    }

    /// Reads the audio world: which devices exist, which one is chosen, and how
    /// loud it is.
    ///
    /// Called when the card appears rather than only when the output button is
    /// pressed. The foot rail draws the *current device's* glyph, so a card that
    /// had never opened the pane showed a generic AirPlay symbol for a Mac
    /// playing through its own speakers; and the volume rail cannot decide
    /// whether it exists until something has asked.
    private func readAudio() {
        outputs = AudioOutputs.available()
        currentOutput = AudioOutputs.current()
        volume = SystemVolume.current()
    }

    private func outputRow(_ device: AudioOutputs.Output) -> some View {
        let selected = device.id == currentOutput
        return Button {
            guard AudioOutputs.select(device.id) else { return }
            currentOutput = AudioOutputs.current()
            volume = SystemVolume.current()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(selected ? .white : .white.opacity(0.7))
                Text(device.name)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent == .white ? .white : accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Three cues, not one: on glass a tint change alone is easy to
            // miss, so the chosen row is lifted, outlined and ticked.
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(selected ? 0.16 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.22 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Rails

    private var fraction: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var seekBar: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                    Capsule().fill(accent.opacity(0.95)).frame(width: width * fraction, height: 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0, media.duration > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0, media.duration > 0 else { return }
                            media.seek(to: media.duration * min(max(value.location.x / width, 0), 1))
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 14)
            HStack {
                Text(formatTime(fraction * media.duration))
                Spacer()
                // What is left, which is the question a lock screen gets asked:
                // how long until this is over.
                Text("-" + formatTime(max(0, media.duration - fraction * media.duration)))
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// The system's output volume. Absent entirely for a device that has none
    /// to give, rather than a slider that moves and changes nothing.
    private var volumeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 10))
            GeometryReader { geo in
                let width = geo.size.width
                let level = Double(draggingVolume ?? volume ?? 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                    Capsule().fill(.white.opacity(0.85)).frame(width: width * level, height: 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            let next = Float(min(max(value.location.x / width, 0), 1))
                            draggingVolume = next
                            SystemVolume.set(next)
                        }
                        .onEnded { _ in
                            volume = SystemVolume.current() ?? draggingVolume
                            draggingVolume = nil
                        }
                )
            }
            .frame(height: 14)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private var transport: some View {
        HStack(spacing: 0) {
            shuffle
            Spacer(minLength: 0)
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 21, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .accessibilityLabel(localized("Previous Track"))
            Spacer(minLength: 0)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Spacer(minLength: 0)
            Button { media.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 21, weight: .medium))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .accessibilityLabel(localized("Next Track"))
            Spacer(minLength: 0)
            repeatToggle
        }
        .frame(height: 34)
    }

    /// Shuffle and repeat keep their places whether or not the source has the
    /// idea, so the row does not change shape between one player and the next.
    private var shuffle: some View {
        ModeToggle(
            symbol: "shuffle",
            isOn: media.shuffleEnabled == true,
            accent: accent,
            size: 32,
            glyphSize: 15
        ) { media.toggleShuffle() }
        .disabled(media.shuffleEnabled == nil)
        .opacity(media.shuffleEnabled == nil ? 0.3 : 1)
        .accessibilityLabel(localized("Shuffle"))
        .accessibilityValue(media.shuffleEnabled == true ? localized("On") : localized("Off"))
    }

    private var repeatToggle: some View {
        ModeToggle(
            symbol: media.repeatMode == .one ? "repeat.1" : "repeat",
            isOn: media.repeatMode != nil && media.repeatMode != .off,
            accent: accent,
            size: 32,
            glyphSize: 15
        ) { media.cycleRepeat() }
        .disabled(media.repeatMode == nil)
        .opacity(media.repeatMode == nil ? 0.3 : 1)
        .accessibilityLabel(localized("Repeat"))
    }

    /// The two doors, and the way back out of either.
    private var footer: some View {
        HStack {
            paneButton(.lyrics, symbol: "quote.bubble", label: localized("Lyrics"))
            Spacer()
            paneButton(.output, symbol: outputSymbol, label: localized("Sound Output"))
        }
        .frame(height: 22)
    }

    private func paneButton(_ target: Pane, symbol: String, label: String) -> some View {
        let open = pane == target
        return Button {
            pane = open ? .player : target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(open ? .white : .white.opacity(0.62))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(open ? [.isSelected] : [])
    }

    private var outputSymbol: String {
        guard let currentOutput,
              let device = outputs.first(where: { $0.id == currentOutput }) else {
            return "airplayaudio"
        }
        return device.symbol
    }

    private var heart: some View {
        Group {
            if spotify.isConnected, !spotify.apiBlocked, !spotify.tokenUnavailable,
               let id = media.spotifyTrackID {
                // Filled means the song is in Liked Songs, hollow means it is
                // not — and until the library has answered, hollow-but-dimmed
                // means "asking". A plain hollow heart while the answer was in
                // flight stated, every time, that a liked song was not liked.
                let known = spotify.saved[id]
                let isSaved = known ?? false
                Button { spotify.toggleSaved(trackID: id) } label: {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSaved ? accent : .white)
                        .opacity(known == nil ? 0.45 : 1)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .disabled(known == nil)
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isSaved ? localized("Remove from Liked Songs") : localized("Add to Liked Songs")
                )
                .task(id: id) { spotify.refreshSavedState(trackID: id) }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Pure layout arithmetic

    /// The line being sung, or the first one when the voice has not reached it.
    static func centreIndex(lines: [LyricsStore.Line], at: TimeInterval) -> Int {
        guard !lines.isEmpty else { return 0 }
        guard let shown = LyricSweep.displayed(lines: lines, at: at) else { return 0 }
        return lines.firstIndex(where: { $0.at == shown.line.at }) ?? 0
    }

    /// A window of `size` indices centred on `centre`, slid inside the song
    /// rather than clipped at its ends — so the first and last lines still show
    /// a full card of words instead of a half-empty one.
    static func window(around centre: Int, count: Int, size: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > size else { return Array(0..<count) }
        let half = size / 2
        let start = min(max(centre - half, 0), count - size)
        return Array(start..<(start + size))
    }
}

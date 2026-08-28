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

    /// How far above the card's foot the output list stops.
    ///
    /// The rail it belongs to is 22pt tall inside 20pt of padding; clearing both
    /// leaves the glyph that opened the list visible underneath it, which is the
    /// half of the rule people actually notice when it is broken.
    static let footerClearance: CGFloat = 20 + 22 + 8

    /// White, always.
    ///
    /// The card used to pull an accent out of the cover and paint the sung
    /// lyric, the scrubber, shuffle, repeat, the tick and the heart with it, so
    /// the whole interface changed colour with the track. Apple's own player
    /// does not do this, and there is a reason beyond taste: an accent taken
    /// from an image lands wherever the image happens to be, which on a pale or
    /// muddy cover is unreadable type on glass. Controls are chrome. They stay
    /// the one colour that works over everything.
    private let accent: Color = .white

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
            .overlay { outputPicker }
            .glassSurface(
                cornerRadius: 30,
                elevation: .card,
                // No tint from the cover either. The glass takes its character
                // from the wallpaper it is actually over, which is the point of
                // it being glass.
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
            // No drop shadow. The system's own lock player has none — the
            // material defines its own edge, and a card floating on a drawn
            // shadow reads as a sticker laid on the wallpaper rather than a
            // pane set into it. These were a contact shadow and a wide soft
            // one; clipped square by a window with no margin they were the
            // dark rectangle behind the corners, and given room to fall they
            // were simply a halo Apple does not draw.
            .environment(\.colorScheme, .dark)
            // A new song puts the card back on the player. Words and a device
            // list both belong to the track that was showing when they were
            // opened, and leaving either up across a change shows one song's
            // pane over another song's title.
            .onChange(of: track.key) { _, _ in pane = .player }
            .onAppear { readAudio() }
            .onChange(of: pane) { _, _ in readAudio() }
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
                    .islandFont(pane == .player ? 18 : 15, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .islandFont(pane == .player ? 14 : 12.5)
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

            // The source badge on the artwork corner — instant context, no text.
            //
            // The app's own icon rather than the first letter of its name. "S"
            // told you nothing that "Spotify" would not have, and told you
            // nothing at all for the two players whose names start the same
            // way. The icon is read before it is parsed, which is the whole job
            // of a badge this size. Falls back to the letter for a source with
            // no icon to give — a helper process, or an app that has quit
            // between the snapshot and the draw.
            sourceBadge
                .offset(x: 4, y: 4)
        }
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: pane)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let icon = media.sourceIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 17, height: 17)
                .clipShape(Circle())
                // A hairline so a light icon still has an edge against a light
                // cover, and a shadow so it reads as sitting on the artwork
                // rather than punched out of it.
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .accessibilityLabel(media.sourceName ?? localized("Sound Output"))
        } else if let source = media.sourceName, !source.isEmpty {
            Text(String(source.prefix(1)))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.black.opacity(0.75)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .accessibilityLabel(source)
        }
    }

    // MARK: - The three middles

    @ViewBuilder
    private var middle: some View {
        ZStack {
            switch pane {
            case .lyrics: lyricsPane
            // The picker is not a pane. It opens *over* the card, the way the
            // system's own output list opens over whatever raised it, so what
            // is playing stays visible behind the thing choosing where it
            // plays.
            case .player, .output: playerPane
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
                let centre = LyricSweep.centreIndex(in: lines, at: at)
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

    private func lyricRow(
        lines: [LyricsStore.Line], index: Int, centre: Int, at: TimeInterval
    ) -> some View {
        LyricRow(
            line: lines[index],
            isCurrent: index == centre,
            distance: abs(index - centre),
            at: at,
            end: LyricSweep.end(of: index, in: lines),
            fontSize: 16,
            weight: .bold,
            lineLimit: 1,
            accent: accent,
            reduceMotion: reduceMotion,
            seek: {
                // The song landing on a line somebody pointed at.
                Haptics.alignment()
                media.seek(to: LyricsStage.clickTarget(
                    lineAt: lines[index].at,
                    lead: LyricSweep.lead(
                        precisionSync: media.precisionSync, userOffset: lyrics.userOffset
                    ),
                    duration: media.duration
                ))
            }
        )
    }

    /// Where the sound goes, presented the way macOS presents it.
    ///
    /// Control Center's output list is the reference, down to the grammar of a
    /// selected row: the device's icon sits in a filled circle in the user's own
    /// accent colour, and the name goes semibold. No tick — the tinted well *is*
    /// the tick there, and adding one states the same thing twice.
    ///
    /// The accent is `controlAccentColor`, which is whatever the person chose in
    /// System Settings. That is not the artwork tint this card used to carry: it
    /// does not move with the music, and matching it is most of what makes a
    /// control feel like it belongs to the system rather than to an app.
    @ViewBuilder
    private var outputPicker: some View {
        if pane == .output {
            ZStack {
                // A real scrim, not an invisible click-catcher.
                //
                // Two reasons, and they are the same reason. Apple's rule for a
                // modal task is to pair the surface with a dimming scrim and
                // push the background back, so attention lands on the thing
                // being chosen. And its rule for materials is never to stack a
                // light translucent surface on another, because legibility
                // collapses — which is exactly what glass-on-glass was doing
                // here, the picker's pane sampling the card's pane.
                //
                // The scrim separates the two layers so each is read against
                // something solid enough, and it is what makes the picker a
                // layer above the card rather than a smudge on it.
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { pane = .player }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Output"))
                        .islandFont(11, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    if outputs.isEmpty {
                        Text(localized("No output devices."))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(outputs.prefix(5)) { device in
                            outputRow(device)
                        }
                    }
                }
                .padding(.vertical, 10)
                .frame(width: 268)
                .glassSurface(cornerRadius: 20, elevation: .popover)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                // Grown from the corner it belongs to, not from the middle of
                // the card. The anchor is what makes it read as *this button's*
                // list rather than as a dialog that happened to appear.
                //
                // And it materialises rather than fading: blur eases out as the
                // scale settles, so the surface reads as glass arriving —
                // coming into focus — instead of a picture of glass turning
                // opaque. A plain opacity fade is the tell that a material is
                // painted on rather than real.
                .transition(.materialize(anchor: .bottomTrailing))
                // Anchored to the control that opened it, which is the rule
                // Apple states outright: a popover points as directly as it can
                // at the element that revealed it, and avoids covering that
                // element. The output glyph sits at the foot of the card on the
                // trailing side, so the list hangs above it and stops short —
                // there is no room below, and growing down would put it over
                // the button and off the card at once.
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomTrailing
                )
                .padding(.trailing, 14)
                .padding(.bottom, Self.footerClearance)
            }
            .animation(reduceMotion ? nil : Theme.paneAnimation, value: pane)
        }
    }

    private func outputRow(_ device: AudioOutputs.Output) -> some View {
        let selected = device.id == currentOutput
        return Button {
            guard AudioOutputs.select(device.id) else { return }
            // A discrete value committed, which is what this pattern is for.
            Haptics.levelChange()
            currentOutput = AudioOutputs.current()
            volume = SystemVolume.current()
            pane = .player
        } label: {
            HStack(spacing: 10) {
                // The filled well, in the system accent. This is the whole
                // selected-state vocabulary in Control Center.
                ZStack {
                    Circle()
                        .fill(selected ? Color(nsColor: .controlAccentColor) : Color.white.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: device.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(device.name)
                    .islandFont(13.5, weight: selected ? .semibold : .regular)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(OutputRowStyle())
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Reads the audio world: which devices exist, which one is chosen, and how
    /// loud it is.
    ///
    /// Called when the card appears rather than only when the output button is
    /// pressed. The foot rail draws the *current device's* glyph, so a card that
    /// had never opened the picker showed a generic AirPlay symbol for a Mac
    /// playing through its own speakers; and the volume rail cannot decide
    /// whether it exists until something has asked.
    private func readAudio() {
        outputs = AudioOutputs.available()
        currentOutput = AudioOutputs.current()
        volume = SystemVolume.current()
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
            .tracking(Theme.tracking(forSize: 11))
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
                        .foregroundStyle(.white)
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

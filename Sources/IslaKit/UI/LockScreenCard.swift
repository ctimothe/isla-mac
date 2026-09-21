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
    var localLookup: () -> LocalLyricsLookup? = { nil }
    /// The machine's audio state, followed while the card is up. The window
    /// starts it before the card exists and stops it at dismiss; a render
    /// without one gets a bare watch, which reads the machine on demand and
    /// never installs listeners.
    @ObservedObject private var audio: AudioWatch
    @ObservedObject private var spotify = SpotifyAccount.shared
    @ObservedObject private var appearance = SystemAppearance.shared
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
    init(
        media: MediaController,
        lyrics: LyricsStore,
        localLookup: @escaping () -> LocalLyricsLookup? = { nil },
        audio: AudioWatch? = nil,
        initialPane: Pane = .player
    ) {
        self.media = media
        self.lyrics = lyrics
        self.localLookup = localLookup
        _audio = ObservedObject(wrappedValue: audio ?? AudioWatch())
        _pane = State(initialValue: initialPane)
    }

    @State private var scrubbing: Double?
    /// The line the words were centred on at the last draw, to tell a line
    /// sung into from a line jumped to.
    @State private var lastCentre: Int?
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

    @AppStorage(NotchViewModel.lockCardSizeKey) private var sizeRaw = NotchViewModel.LockCardSize.standard.rawValue

    private var cardSize: NotchViewModel.LockCardSize {
        NotchViewModel.LockCardSize(rawValue: sizeRaw) ?? .standard
    }

    /// The size the lock window is cut to, read when it is made. A setting
    /// changed mid-lock applies at the next lock: the window is never resized
    /// while it stands.
    static var size: CGSize { size(for: NotchViewModel.lockCardSize) }

    static func size(for cardSize: NotchViewModel.LockCardSize) -> CGSize {
        switch cardSize {
        case .standard: return CGSize(width: 460, height: 300)
        case .compact: return CGSize(width: 420, height: 244)
        }
    }

    private var dimensions: CGSize { Self.size(for: cardSize) }

    /// How many lyric lines the middle shows. Odd, so the line being sung sits
    /// in the centre with the same amount of song either side of it.
    static let visibleLyricLines = 5

    static func visibleLyricLines(for cardSize: NotchViewModel.LockCardSize) -> Int {
        cardSize == .compact ? 3 : visibleLyricLines
    }

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
                Spacer(minLength: 10)
                middle
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 10)
                transport
                rail
                    .padding(.top, 14)
            }
            .padding(.horizontal, cardSize == .compact ? 20 : 24)
            .padding(.top, cardSize == .compact ? 18 : 22)
            .padding(.bottom, cardSize == .compact ? 14 : 18)
            // Every mark on the card carries its own shadow on glass. That is
            // how white type survives a bright wallpaper without a scrim
            // painting the wallpaper out — the system does the same on its own
            // lock screen, and it is why the clock there is readable over
            // anything.
            // More of the wallpaper shows through Transparent, so its type
            // carries more shadow to stay legible over it.
            .shadow(color: .black.opacity(style == .solid ? 0 : (style == .clear ? 0.5 : 0.35)), radius: 3, y: 1)
            .frame(width: dimensions.width, height: dimensions.height)
            .overlay { outputPicker }
            .background { coverLight }
            .glassSurface(
                cornerRadius: 30,
                elevation: .card,
                // No tint from the cover either. The glass takes its character
                // from the wallpaper it is actually over, which is the point of
                // it being glass.
                samplesBackdrop: style != .solid && media.artwork == nil,
                // Solid is the panel Reduce Transparency draws, chosen on
                // purpose. It used to be the drawn glass laid over an
                // `.ultraThinMaterial` and a black scrim — three surfaces for
                // one card, and above the shield the material had nothing to
                // sample anyway, so what it added was a muddier version of the
                // recipe already on top of it. One surface, one rule.
                solid: style == .solid
            )
            // No drop shadow. The system's own lock player has none — the
            // material defines its own edge, and a card floating on a drawn
            // shadow reads as a sticker laid on the wallpaper rather than a
            // pane set into it. These were a contact shadow and a wide soft
            // one; clipped square by a window with no margin they were the
            // dark rectangle behind the corners, and given room to fall they
            // were simply a halo Apple does not draw.
            .environment(\.colorScheme, .dark)
            // A new song leaves the card where it was. It used to put the card
            // back on the player, on the reasoning that words belong to the
            // song that was showing — but the words pane follows the song, and
            // Apple Music's lyrics stay up from one song to the next. Filmed on
            // 2026-09-21: lyrics opened, a skip, and the card closed them, so
            // every new song had to be opened again by hand.
            .onAppear { readAudio() }
            .onChange(of: pane) { _, _ in readAudio() }
            // The machine moves on its own while the card stands here — a
            // device connecting mid-lock, the volume keys — and the card used
            // to miss every bit of it until a pane switch re-read. The watch's
            // listeners speak for the card now; a finger on the bar owns the
            // level until release, so its mirror stands down while one drags.
            .onReceive(audio.$outputs) { outputs = $0 }
            .onReceive(audio.$current) { currentOutput = $0 }
            .onReceive(audio.$volume) { newValue in
                guard draggingVolume == nil else { return }
                volume = newValue
            }
            .transition(.opacity)
        }
    }

    // MARK: - Cover light

    /// The cover, lighting the card from behind — blurred past recognition,
    /// saturated a little, and dimmed so white type holds over the palest one.
    ///
    /// The card used to be glass lit by nothing. Above the login shield a
    /// material has nothing to sample, so what arrived was a grey slab laid on
    /// the wallpaper — "more like a fake one", the owner said on 2026-09-21,
    /// next to the players Apple ships. Apple Music's player and the lock
    /// screen's own since iOS 26 put the music behind the controls, and so does
    /// this. Glass only: Solid stays the neutral panel it promises, and with no
    /// cover the glass falls back to sampling what it can.
    @ViewBuilder
    private var coverLight: some View {
        if style != .solid, let image = media.artwork {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: dimensions.width, height: dimensions.height)
                    // Oversized before the blur, so the blur has no soft,
                    // darker rim to show at the card's edge.
                    .scaleEffect(1.5)
                    .blur(radius: 44, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(appearance.increaseContrast ? 0.56 : (style == .clear ? 0.2 : 0.34))
                LinearGradient(
                    colors: [.clear, .black.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: dimensions.width, height: dimensions.height)
            // Transparent lets the wallpaper through the cover's light, the
            // most glass a card above the login shield can be: no window up
            // there is given a backdrop to blur. Increase Contrast keeps it
            // opaque — see-through is exactly what that setting asks against.
            .opacity(style == .clear && !appearance.increaseContrast ? 0.62 : 1)
            .clipped()
            .animation(reduceMotion ? nil : Theme.artworkAnimation, value: media.artwork)
        }
    }

    // MARK: - Header

    private func header(_ track: MediaController.Track) -> some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .islandFont(.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .islandFont(.subhead, weight: .regular)
                    .foregroundStyle(Theme.cardSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Beside the title, the way a player keeps its love button with
            // the song — not stamped on the cover's corner, where it read as
            // part of the artwork.
            heart
        }
        .animation(reduceMotion ? nil : Theme.contentAnimation, value: pane)
    }

    /// The cover shrinks when a pane needs the room, and the card does not.
    private var artwork: some View {
        let side: CGFloat = cardSize == .compact
            ? (pane == .player ? 58 : 38)
            : (pane == .player ? 76 : 44)
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(
                            Image(systemName: "music.note")
                                // A third of the cover's side, at either cover
                                // size — a proportion, not a size, so no role
                                // can name it.
                                .font(.system(size: side / 3, weight: .light))
                                .foregroundStyle(Theme.cardTertiary)
                        )
                }
            }
            .frame(width: side, height: side)
            // A cover's corner, not an app icon's: Apple rounds artwork gently,
            // about a seventh of its side, and a deeper curve reads as a tile.
            .clipShape(RoundedRectangle(cornerRadius: side / 7, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

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
            // The icon as the app draws it, the way Control Center badges its
            // Now Playing cover — not cut into a circle with a ring around it,
            // which made every app's icon into the same foreign badge.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .accessibilityLabel(media.sourceName ?? localized("Sound Output"))
        } else if let source = media.sourceName, !source.isEmpty {
            Text(String(source.prefix(1)))
                .islandFont(.caption, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.black.opacity(0.75)))
                .overlay(Circle().strokeBorder(Theme.cardHairline, lineWidth: 0.5))
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            seekBar
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
            if case .ready = lyrics.availability,
               case .synced(let lines) = lyrics.state,
               !lines.isEmpty {
                let at = LyricSweep.position(
                    media.position,
                    precisionSync: media.precisionSync,
                    userOffset: lyrics.userOffset,
                    trackOffset: lyrics.trackOffset
                )
                let centre = LyricSweep.centreIndex(in: lines, at: at)
                let window = Self.window(around: centre, count: lines.count, size: Self.visibleLyricLines(for: cardSize))
                let jump = Self.isJump(from: lastCentre, to: centre)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(window, id: \.self) { index in
                        lyricRow(lines: lines, index: index, centre: centre, at: at)
                            .transition(Self.lineTransition(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The page moves when the song moves a line. It used to jump:
                // nothing here animated the window sliding, so every row leapt
                // a slot at once while only the highlight crossfaded — the one
                // lyric surface on the Mac whose words did not travel. Now the
                // line leaving goes up and out with the rest of the page and
                // the next one rises in from under the bottom, on the same
                // spring the stage scrolls with, clipped to the window so
                // neither is drawn over the title above or the rail below.
                .clipped()
                .animation(jump ? nil : Theme.lyricScroll(reduceMotion: reduceMotion), value: centre)
                // A jump is a cut. When a seek moves the words more than a line,
                // every row is replaced at once, and each one's own crossfade
                // laid the old line and the new one over each other in the same
                // slot — two lyrics legible at once, filmed on 2026-09-21. A
                // line reached by singing still lights up on the lyric spring;
                // a line reached by clicking is simply there.
                .transaction { transaction in
                    if Self.isJump(from: lastCentre, to: centre) {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .onChange(of: centre) { _, now in lastCentre = now }
                .onAppear { lastCentre = centre }
            } else {
                VStack(spacing: 8) {
                    if case .findingLocalLyrics = lyrics.availability {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    // `.resolving` draws neither spinner nor text: the status
                    // line below it is empty for that state by design.
                    // The status, and nothing to press. A Retry button here
                    // could not even fit its word — "R…" — and a lock screen's
                    // player never offers one; a failed lookup asks again by
                    // itself (see `LyricsCoordinator.retryDelays`).
                    Text(lyricsStatus)
                        .islandFont(.subhead, weight: .regular)
                        .foregroundStyle(Theme.cardTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var lyricsStatus: String {
        LyricsPresentation.compactCaption(
            for: lyrics.availability, currentLine: nil, localLookup: localLookup(),
            onlineEnabled: NotchViewModel.onlineLyricsEnabled
        )
    }

    private var wordTimingEnabled: Bool {
        LyricsPresentation.usesWordTiming(
            lyrics.timingGranularity,
            precisionMeasured: media.precisionSync,
            wordKaraokeEnabled: lyrics.wordKaraokeEnabled
        )
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
            fontSize: Theme.TypeRole.title.size,
            weight: .bold,
            lineLimit: 1,
            accent: accent,
            reduceMotion: reduceMotion,
            wordTimingEnabled: wordTimingEnabled,
            seek: {
                // The song landing on a line somebody pointed at.
                Haptics.alignment()
                media.seek(to: LyricsStage.clickTarget(
                    lineAt: lines[index].at,
                    lead: LyricSweep.lead(
                        precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                        trackOffset: lyrics.trackOffset
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
                        .islandFont(.body, weight: .semibold)
                        .foregroundStyle(Theme.cardTertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    if outputs.isEmpty {
                        Text(localized("No output devices."))
                            .islandFont(.subhead, weight: .regular)
                            .foregroundStyle(Theme.cardTertiary)
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
                .transition(reduceMotion ? .opacity : .materialize(anchor: .bottomTrailing))
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
            // Through the watch, not straight into state: the volume listener
            // has to follow the device we just made default, and one re-read
            // mirrors everything — list, highlight, level — back into the card.
            readAudio()
            pane = .player
        } label: {
            HStack(spacing: 10) {
                // The filled well, in the system accent. This is the whole
                // selected-state vocabulary in Control Center.
                ZStack {
                    Circle()
                        .fill(selected ? Color(nsColor: .controlAccentColor) : Theme.cardFill)
                        .frame(width: 26, height: 26)
                    Image(systemName: device.symbol)
                        .islandFont(.subhead)
                        .foregroundStyle(.white)
                }
                Text(device.name)
                    .islandFont(.subhead, weight: selected ? .semibold : .regular)
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
    /// One re-read of the machine, mirrored straight into the card's state.
    ///
    /// Everything audio now flows through the watch — this asks it to re-read
    /// and copies what it found, so the pane-change and selection paths and the
    /// listener-driven path all publish through one place. Direct reads here
    /// would leave the watch's picture of the machine behind the card's, and
    /// the volume listener would follow the old default after a selection.
    private func readAudio() {
        audio.systemAudioChanged()
        outputs = audio.outputs
        currentOutput = audio.current
        volume = audio.volume
    }

    // MARK: - Rails

    private var fraction: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    /// The elapsed time for the labels: the finger while dragging, otherwise
    /// the clock's steady label position, which never steps back a second
    /// for a small correction.
    private var shownElapsed: TimeInterval {
        if let scrubbing { return scrubbing * media.duration }
        return min(media.labelPosition, media.duration)
    }

    private var seekBar: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardTrack).frame(height: 6)
                    Capsule().fill(accent.opacity(0.9)).frame(width: width * fraction, height: 6)
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
            // One adjustable element, the way the panel's scrubber is declared:
            // a capsule with a drag gesture is nothing at all to assistive
            // tech, and over the lock screen this is the only way to move the
            // song without a pointer.
            .accessibilityElement()
            .accessibilityLabel(localized("Playback Position"))
            .accessibilityValue(
                localized(
                    "%@ of %@",
                    formatTime(fraction * media.duration),
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
            HStack {
                Text(formatTime(shownElapsed))
                Spacer()
                // What is left, which is the question a lock screen gets asked:
                // how long until this is over.
                Text("-" + formatTime(max(0, media.duration - shownElapsed)))
            }
            // Small and quiet, as the system sets a player's times: they are
            // read in passing, and bold numerals at the body size shouted over
            // the song they belong to.
            .font(Theme.TypeRole.body.font(weight: .medium).monospacedDigit())
            .tracking(Theme.tracking(forSize: Theme.TypeRole.body.size))
            .foregroundStyle(Theme.cardTertiary)
        }
    }

    /// Where the volume bar stands, 0...1: the finger while dragging, else the
    /// device.
    private var volumeLevel: Double { Double(draggingVolume ?? volume ?? 0) }

    /// The system's output volume. Absent entirely for a device that has none
    /// to give, rather than a slider that moves and changes nothing.
    private var volumeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").islandFont(.caption, weight: .regular)
            GeometryReader { geo in
                let width = geo.size.width
                let level = Double(draggingVolume ?? volume ?? 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardTrack).frame(height: 4)
                    Capsule().fill(.white.opacity(0.8)).frame(width: width * level, height: 4)
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
            // The same contract as the seek bar above: heard as a percentage,
            // moved in five-percent steps. This is the system's output volume,
            // and it was invisible to VoiceOver.
            .accessibilityElement()
            .accessibilityLabel(localized("Volume"))
            .accessibilityValue(Text(volumeLevel, format: .percent))
            .accessibilityAdjustableAction { direction in
                let step: Float = 0.05
                let current = Float(volumeLevel)
                let next: Float
                switch direction {
                case .increment: next = min(current + step, 1)
                case .decrement: next = max(current - step, 0)
                @unknown default: return
                }
                SystemVolume.set(next)
                volume = SystemVolume.current() ?? next
            }
            Image(systemName: "speaker.wave.3.fill").islandFont(.caption, weight: .regular)
        }
        .foregroundStyle(Theme.cardSecondary)
    }

    /// Previous, play and next, centred — and nothing else.
    ///
    /// A lock screen's player carries the three and leaves shuffle and repeat
    /// to the app: they are settings, not transport, and Apple's own lock
    /// players have never set them from there. Pinned to the card's two ends
    /// they made the row read as an app's toolbar rather than the system's
    /// player. They stay in the panel, where the rest of the app is.
    private var transport: some View {
        HStack(spacing: 44) {
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").islandFont(.display)
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Previous Track"))
            .accessibilityLabel(localized("Previous Track"))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .islandFont(.hero)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Button { media.next() } label: {
                Image(systemName: "forward.fill").islandFont(.display)
            }
            .buttonStyle(TransportGlyphStyle(size: 34))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Next Track"))
            .accessibilityLabel(localized("Next Track"))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    /// The foot rail: the words, the level, and where the sound goes.
    ///
    /// The Music app's player keeps its lyrics door and its output picker at
    /// its foot, with the volume between them, and so does this. The volume
    /// used to sit between the scrubber and the transport, where no Apple
    /// player puts it.
    private var rail: some View {
        HStack(spacing: 14) {
            paneButton(.lyrics, symbol: "quote.bubble", label: localized("Lyrics"))
            if volume != nil {
                volumeBar
            } else {
                Spacer(minLength: 0)
            }
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
                .islandFont(.subhead, weight: .medium)
                .foregroundStyle(open ? Color.white : Theme.cardSecondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
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
                        .islandFont(.title, weight: .medium)
                        .foregroundStyle(isSaved ? Color.white : Theme.cardSecondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                        .opacity(known == nil ? 0.45 : 1)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .disabled(known == nil)
                .buttonStyle(PanelButtonStyle())
                .accessibilityLabel(
                    isSaved ? localized("Remove from Liked Songs") : localized("Add to Liked Songs")
                )
                .task(id: id) { spotify.refreshSavedState(trackID: id) }
            }
        }
    }

    // MARK: - Pure layout arithmetic

    /// How far a line travels entering or leaving the window: one row of the
    /// title role plus the stack's spacing, so the leaving line moves exactly
    /// as far as the lines behind it and the arriving one starts where the
    /// next row would have been. The page moves as one.
    static let lineTravel: CGFloat = 26

    static func lineTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: lineTravel)),
            removal: .opacity.combined(with: .offset(y: -lineTravel))
        )
    }

    /// Whether the centre moved by more than one line: a seek, not singing.
    static func isJump(from previous: Int?, to centre: Int) -> Bool {
        guard let previous else { return false }
        return abs(centre - previous) > 1
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

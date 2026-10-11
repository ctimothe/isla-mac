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
    /// The row the words were centred on at the last draw, to tell a line
    /// sung into from a line jumped to. A slot index (`LyricSweep.slots`),
    /// not a line index: an interlude is a row, and comparing a slot against
    /// a line index would call the step out of every solo a seek.
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

    private var glassRoute: (samplesBackdrop: Bool, preferDrawn: Bool, solid: Bool) {
        Self.glassRouting(style: style, hasArtwork: media.artwork != nil)
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

    /// Which glass the card asks `glassSurface` for: always the drawn recipe.
    ///
    /// checklist.md has said so since the card went over the shield — the
    /// shield is protected content, no window above it is given a backdrop to
    /// blur, so the glass is a recipe and not a sample, as the system's own
    /// lock-screen widgets are. The code disagreed (F-012). A coverless
    /// Transparent or Tinted card asked for a backdrop and nothing more, so on
    /// macOS 26 it took `glassEffect` with nothing to sample and the cover
    /// light gone, while a card with a cover drew the recipe.
    ///
    /// That split had a second cost (K-017). `GlassSurfaceStyle` picks
    /// between `glassEffect` and the recipe with an `if`, so when a coverless
    /// song followed one with art the card's whole content changed identity,
    /// and a scrub or volume drag in flight was torn down without its
    /// `onEnded` — the bar stayed pinned to the old finger. `preferDrawn`
    /// held constant keeps the branch where it is; only the vibrancy laid
    /// under the recipe follows the cover, and that lives in the background.
    ///
    /// The `drawnGlass` default stays for the panel. It was the escape hatch
    /// for this card while the question was open, and the record closed it.
    static func glassRouting(
        style: NotchViewModel.LockCardStyle, hasArtwork: Bool
    ) -> (samplesBackdrop: Bool, preferDrawn: Bool, solid: Bool) {
        (samplesBackdrop: style != .solid && !hasArtwork, preferDrawn: true, solid: style == .solid)
    }

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

    // MARK: Output list

    /// One row of the output list: the 26pt well and 5pt above and below it.
    static let outputRowHeight: CGFloat = 26 + 5 * 2
    static let outputRowSpacing: CGFloat = 2
    /// What the popover spends on itself above the rows: 10pt of padding top
    /// and bottom, and the "Output" heading with its own 4pt and the stack's
    /// 2pt under it. An allowance rather than a measurement, rounded up, so
    /// the arithmetic below errs towards one row fewer, never off the card.
    static let outputPopoverChrome: CGFloat = 10 * 2 + 20

    /// The devices in the order the picker lists them: the one playing first,
    /// the rest in the order the system gives them.
    ///
    /// The list used to be `outputs.prefix(5)`, in the system's order and
    /// nothing else. A Mac with a display, AirPods, an AirPlay speaker and a
    /// virtual driver or two has more than five, and the device playing could
    /// be the sixth — not shown, so not something anyone could pick again from
    /// the lock screen (F-032). Pinning it first means the row that answers
    /// "where is this going" is always the one in view; only that row moves,
    /// so the order of the rest is still the one Control Center shows.
    static func orderedOutputs(
        _ outputs: [AudioOutputs.Output], current: AudioDeviceID?
    ) -> [AudioOutputs.Output] {
        guard let current, let index = outputs.firstIndex(where: { $0.id == current }) else { return outputs }
        var ordered = outputs
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    /// How many whole rows fit between the card's top edge and the footer the
    /// list must not cover. Five on the standard card, four on the compact one —
    /// which is why a fixed five was never right: on the compact card five rows
    /// already ran off the top of the card.
    static func outputRowsThatFit(_ size: NotchViewModel.LockCardSize) -> Int {
        let room = Self.size(for: size).height - footerClearance - outputPopoverChrome
        return max(1, Int((room + outputRowSpacing) / (outputRowHeight + outputRowSpacing)))
    }

    /// The height of the scrolling list, for `count` devices.
    ///
    /// Up to the cap, exactly as tall as its rows. Past it, the last visible
    /// row is cut in half. The list scrolls without indicators — over the
    /// shield an overlay scroller only appears once someone is already
    /// scrolling — so a row sliced by the edge is the thing that says there is
    /// more below. A list that ended on a whole row would look complete.
    static func outputListHeight(count: Int, size: NotchViewModel.LockCardSize) -> CGFloat {
        guard count > 0 else { return 0 }
        let fit = outputRowsThatFit(size)
        let pitch = outputRowHeight + outputRowSpacing
        if count <= fit { return CGFloat(count) * pitch - outputRowSpacing }
        return CGFloat(fit - 1) * pitch + outputRowHeight / 2
    }

    /// The card tokens a picker row is drawn in.
    enum OutputInk: Equatable {
        case primary, cardTertiary, cardFill

        @MainActor var color: Color {
            switch self {
            case .primary: return .white
            case .cardTertiary: return Theme.cardTertiary
            case .cardFill: return Theme.cardFill
            }
        }
    }

    /// What tells the selected row from the others.
    struct OutputRowMarks: Equatable {
        var checkmark: Bool
        var semibold: Bool
        var well: OutputInk
        var glyph: OutputInk
    }

    /// The selected device carries a trailing checkmark and a semibold name;
    /// the others carry neither, and their glyph steps down to the tertiary
    /// ink. The well is the same neutral shape on every row.
    ///
    /// It used to be Control Center's grammar exactly — a white glyph in a
    /// well of the person's own accent colour, and no tick, on the argument
    /// that the tinted well *was* the tick. That argument fails on a light
    /// accent: white on Yellow is about 1.4:1, so the glyph vanished and the
    /// selection was told by colour alone (F-053). A dark glyph on light
    /// accents would need luminance arithmetic and still lean on colour; the
    /// accent with a checkmark added keeps a glyph that fails 3:1. A checkmark
    /// and a weight are a shape and a stroke, and read the same under any
    /// accent, any wallpaper and any colour vision.
    static func outputRowMarks(selected: Bool) -> OutputRowMarks {
        OutputRowMarks(
            checkmark: selected,
            semibold: selected,
            well: .cardFill,
            glyph: selected ? .primary : .cardTertiary
        )
    }

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
                samplesBackdrop: glassRoute.samplesBackdrop,
                // Always the recipe, never Apple's material: see
                // `glassRouting`, which is what the tests hold.
                preferDrawn: glassRoute.preferDrawn,
                // Solid is the panel Reduce Transparency draws, chosen on
                // purpose. It used to be the drawn glass laid over an
                // `.ultraThinMaterial` and a black scrim — three surfaces for
                // one card, and above the shield the material had nothing to
                // sample anyway, so what it added was a muddier version of the
                // recipe already on top of it. One surface, one rule.
                solid: glassRoute.solid
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
            // A skip on the card swaps the title in place, which a sighted
            // listener sees and a VoiceOver user used to have to go and find.
            // Only a change is spoken, not the card arriving: the shield going
            // up is not news about the music. The card exists only while it is
            // presented — its window is destroyed at unlock — so nothing here
            // speaks for a Mac that is not locked, and the island's own peek is
            // refused over the shield, so the two never say one track twice.
            .onChange(of: media.track?.key) { _, _ in
                // A drag that a new song cut short lets go here (K-017). A
                // gesture torn down without `onEnded` left the seek bar pinned
                // to the old finger and the volume mirror deaf until the next
                // drag. A finger still down simply writes its place again on
                // the next move, so nothing live is lost by clearing these.
                scrubbing = nil
                if draggingVolume != nil {
                    draggingVolume = nil
                    volume = audio.volume
                }
                guard let now = media.track else { return }
                Announcer.shared.announce(now.artist.isEmpty ? now.title : "\(now.title), \(now.artist)")
            }
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
    /// "Dimmed" was a fixed 0.34 black until F-003 measured it: over a
    /// near-white cover the artist line read at 1.76:1. The wash now comes
    /// from `LockCardLegibility`, scaled to how bright this cover is — today's
    /// value for a dark one, just enough more for a pale one to hold AA.
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
                    // darker rim to show at the card's edge. The zoom is
                    // `LockCardLegibility`'s, because its measurement of the
                    // cover crops to exactly what this leaves showing.
                    .scaleEffect(LockCardLegibility.coverZoom)
                    .blur(radius: 44, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(LockCardLegibility.washOpacity(
                    coverLuma: LockCardLegibility.coverLuma(of: image),
                    style: style,
                    increaseContrast: appearance.increaseContrast
                ))
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
        // On the header, not the heart. The heart is not drawn while Spotify
        // refuses the account, and while its task was the only thing that
        // asked, nothing ever asked again: one 403 hid it for good. Here the
        // lookup runs for every Spotify track whether or not the heart shows,
        // and the account decides whether its cooldown allows a request.
        // Keyed on the connection too, so connecting with the card up asks.
        .task(id: HeartLookup(trackID: media.spotifyTrackID, connected: spotify.isConnected)) {
            if let id = media.spotifyTrackID { spotify.refreshSavedState(trackID: id) }
        }
    }

    private struct HeartLookup: Equatable {
        let trackID: String?
        let connected: Bool
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
                let resolution = Self.resolve(lines: lines, inputs: LyricInputs(
                    position: media.position,
                    precisionSync: media.precisionSync,
                    userOffset: lyrics.userOffset,
                    trackOffset: lyrics.trackOffset,
                    wordTiming: wordTimingEnabled
                ))
                // The window is over slots, not lines: through a solo the
                // middle row is the interlude marker, filling toward the line
                // below it. Everything that counts rows here — `centre`,
                // `lastCentre`, the window and the jump test — counts slots,
                // so singing into an interlude and out of it is two steps of
                // one row, never a seek.
                let slots = LyricSweep.slots(for: lines)
                let centre = LyricSweep.slotIndex(of: resolution.moment.centreSlot, in: slots)
                let lit = LyricSweep.litSlotIndex(resolution.moment, in: slots)
                let window = Self.window(around: centre, count: slots.count, size: Self.visibleLyricLines(for: cardSize))
                let jump = Self.isJump(from: lastCentre, to: centre)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(window, id: \.self) { position in
                        Group {
                            switch slots[position] {
                            case .line(let index):
                                lyricRow(
                                    lines: lines, index: index, resolution: resolution,
                                    distance: LyricSweep.distance(ofSlot: position, lit: lit)
                                )
                            case .interlude:
                                interludeRow(
                                    slots[position], resolution: resolution,
                                    distance: LyricSweep.distance(ofSlot: position, lit: lit)
                                )
                            }
                        }
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
                // Reduce Motion keeps the old cut: with the travel refused the
                // leaving line only faded while the rest still slid a row, so
                // for a moment two lines shared one slot.
                .animation(jump || reduceMotion ? nil : Theme.lyricScroll, value: centre)
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

    /// What the card draws for one reading of the clock: the window centres on
    /// `centre`, and only `current` is drawn as sung. The card used to pass
    /// the centre as `isCurrent`, so through every intro it filled line 1 as
    /// though the voice were in it while the stage and the caption both showed
    /// it waiting — a median 12.9 s of each of the lyric lab's 540 tracks. The
    /// lab calls this function, not a copy of it.
    static func resolve(lines: [LyricsStore.Line], inputs: LyricInputs) -> LyricResolution {
        LyricSweep.resolve(lines: lines, inputs: inputs)
    }

    private func lyricRow(
        lines: [LyricsStore.Line], index: Int, resolution: LyricResolution, distance: Int
    ) -> some View {
        LyricRow(
            line: lines[index],
            isCurrent: index == resolution.current,
            // Measured from the lit row, in rows, as on the stage: from the
            // centre, the waiting opening line sat at the far floor beside a
            // brighter neighbour.
            distance: distance,
            at: resolution.at,
            end: LyricSweep.end(of: index, in: lines),
            // The sung row's edge read per frame from the running clock, as
            // on the stage and the caption.
            clock: index == resolution.current
                ? LyricSweep.frameClock(media: media, lead: LyricSweep.lead(
                    precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                    trackOffset: lyrics.trackOffset
                ))
                : nil,
            fontSize: Theme.TypeRole.title.size,
            weight: .bold,
            lineLimit: 1,
            accent: accent,
            reduceMotion: reduceMotion,
            wordTimingEnabled: wordTimingEnabled,
            // The card's own steps. The panel's were tuned against black, and
            // over a pale cover its context lines dissolved (2.1:1 at the floor).
            surface: .card,
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

    /// The silence before a line, in the row a line would take — the same
    /// marker the stage draws, at the card's type size so the window's rows
    /// keep one height.
    private func interludeRow(
        _ slot: LyricSlot, resolution: LyricResolution, distance: Int
    ) -> some View {
        let isCurrent = slot == resolution.moment.interlude
        return InterludeMarker(
            progress: LyricSweep.interludeProgress(slot, at: resolution.at),
            isCurrent: isCurrent,
            distance: distance,
            clock: isCurrent
                ? LyricSweep.liveProgress(slot, clock: LyricSweep.frameClock(media: media, lead: LyricSweep.lead(
                    precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                    trackOffset: lyrics.trackOffset
                )))
                : nil,
            fontSize: Theme.TypeRole.title.size,
            weight: .bold,
            reduceMotion: reduceMotion,
            surface: .card
        )
    }

    /// Where the sound goes, presented the way macOS presents it.
    ///
    /// Control Center's output list is the reference for the shape of it: an
    /// icon in a round well, the name beside it, the list hanging off the
    /// control that raised it. The selected row departs from it on purpose —
    /// see `outputRowMarks` for why the accent well became a checkmark.
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
                        // Every device, the current one first, in a list that
                        // scrolls rather than grows: past what fits above the
                        // footer it would cover the glyph that opened it, and
                        // past the card's top edge it would be cut by the
                        // window. `.basedOnSize` keeps a short list from
                        // rubber-banding as if it had somewhere to go.
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: Self.outputRowSpacing) {
                                ForEach(Self.orderedOutputs(outputs, current: currentOutput)) { device in
                                    outputRow(device)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: Self.outputListHeight(count: outputs.count, size: cardSize))
                    }
                }
                .padding(.vertical, 10)
                .frame(width: 268)
                // The recipe here too (F-012). Left to the default it took
                // `glassEffect` on macOS 26 and stacked real glass on the
                // card's recipe under the scrim — the glass-on-glass the scrim
                // above exists to prevent, and the same shield with nothing
                // behind it to sample. The recipe's vibrancy layer stays, as it
                // always was below 26: over the shield it samples nothing and
                // the drawn pane carries the surface on its own.
                .glassSurface(cornerRadius: 20, elevation: .popover, preferDrawn: true)
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
        let marks = Self.outputRowMarks(selected: selected)
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
                ZStack {
                    Circle()
                        .fill(marks.well.color)
                        .frame(width: 26, height: 26)
                    Image(systemName: device.symbol)
                        .islandFont(.subhead)
                        .foregroundStyle(marks.glyph.color)
                }
                Text(device.name)
                    .islandFont(.subhead, weight: marks.semibold ? .semibold : .regular)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if marks.checkmark {
                    // Hidden from VoiceOver: the row already says "selected"
                    // through its trait, and a second "checkmark" would be
                    // the same fact twice.
                    Image(systemName: "checkmark")
                        .islandFont(.caption, weight: .semibold)
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // The row's height is arithmetic the list is cut to (see
            // `outputListHeight`), so it is stated rather than left to the
            // font: a taller name must not push the half-row off its half.
            .frame(height: Self.outputRowHeight)
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
            // 22 pt to grab inside the 14 pt the card lays out, as the
            // panel's scrubber does (F-014): the bar is drawn the same, the
            // times under it do not move, and a finger that lands a little
            // high or low still seeks.
            .frame(height: 22)
            // The same slider the panel's scrubber is: over the lock screen
            // this is the only way to move the song without a pointer.
            .playbackPositionAccessibility(
                shown: fraction * media.duration,
                duration: media.duration,
                position: { media.position },
                seek: { media.seek(to: $0) }
            )
            .padding(.vertical, -4)
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
            // The whole height of the rail to grab: the rail is 22 pt, so the
            // strip grows into it without moving anything beside it (F-014).
            .frame(height: 22)
            // The same slider as the seek bar above, heard as a percentage and
            // moved in five-percent steps. This is the system's output volume,
            // and the dump found it as an AXUnknown with no value (H-023).
            .volumeAccessibility(level: volumeLevel) { level in
                let next = Float(level)
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

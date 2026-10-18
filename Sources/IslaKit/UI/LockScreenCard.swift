import CoreAudio
import SwiftUI

/// The media player shown while the Mac is locked: a slim banner that grows into
/// a card (redesign 2026-10-15, spec §7).
///
/// **One object, two forms.** The song rests as a 360 x 64 banner under the
/// clock when Rest as Banner is on (the default); a click anywhere on it but its
/// play button grows it into the card **in place** — same top edge, same centre
/// x, `Theme.lockCardMorph` — so the cover, the title and the artist travel down
/// and out rather than being swapped. The card's chevron shrinks it back. With
/// the switch off the card shows directly, with no chevron, as it did before.
/// Every frame is `LockCardLayout`'s.
///
/// The card is laid out the way the system's own lock-screen player is: the
/// track across the top, the sung line, the scrubber, the transport, and a rail
/// of secondary actions at the foot. Two panes replace the card's body — the
/// lyrics, and the Sound module's output list — and both come back with their
/// Back chevron.
///
/// **The window is one fixed size in every state.** It has its own window above
/// the login shield, cut once to the largest card, and that window is never
/// resized: the window server snapshots windows across a lock transition, and a
/// snapshot taken at one size stretched into another is precisely the
/// half-scale off-centre card this window was created to end. So the states
/// change what is drawn, never how much room it takes — a banner is drawn in the
/// top of the card's area and the window's hit-test follows the visible shape
/// (`LockCardRootView`).
///
/// Interactive, deliberately: the transport, the scrubber, each lyric line and
/// each output row answer clicks, and the window's hit region is exactly the
/// visible banner or card — the rest of the lock screen still belongs to the
/// password field.
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
    /// The translated line under the sung one (spec §7.1). The session's
    /// service in the app; the idle one — which translates nothing — in a
    /// render. Observed, so the line arrives the moment its batch does.
    @ObservedObject private var translation: LyricTranslation
    /// How bright the wallpaper behind the card is, for Automatic's opacity.
    @ObservedObject private var tone: LockCardToneModel
    /// Which form and which pane, shared with the window (its hit-test reads it)
    /// and with the translation service (it is wanted only while this is the card).
    @ObservedObject private var presentation: LockCardPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which body the card shows. One value rather than a set of bools, so two
    /// panes can never be open at once — which is what a `showingOutputs` and a
    /// `showingLyrics` flag will eventually do to each other.
    enum Pane: String, CaseIterable {
        case player, lyrics, output
    }

    private var pane: Pane {
        get { presentation.pane }
        nonmutating set { presentation.pane = newValue }
    }

    private var form: LockCardLayout.Form { presentation.form }

    /// - Parameter initialPane: which pane the card opens on, when no
    ///   presentation is handed in. Always `.player` in the app; the parameter
    ///   exists so a render can photograph the other two without a click.
    /// - Parameter presentation: the window's. Without one the card is the card
    ///   — no banner to rest as, no chevron — which is what a render, a lab and
    ///   every test that reaches for the player's controls want.
    init(
        media: MediaController,
        lyrics: LyricsStore,
        localLookup: @escaping () -> LocalLyricsLookup? = { nil },
        audio: AudioWatch? = nil,
        initialPane: Pane = .player,
        translation: LyricTranslation? = nil,
        tone: LockCardToneModel? = nil,
        presentation: LockCardPresentation? = nil
    ) {
        self.media = media
        self.lyrics = lyrics
        self.localLookup = localLookup
        let watch = audio ?? AudioWatch()
        _audio = ObservedObject(wrappedValue: watch)
        _volumeSlider = StateObject(wrappedValue: VolumeSliderModel(audio: watch))
        _translation = ObservedObject(wrappedValue: translation ?? .idle)
        _tone = ObservedObject(wrappedValue: tone ?? LockCardToneModel())
        _presentation = ObservedObject(
            wrappedValue: presentation ?? LockCardPresentation(restsAsBanner: false, pane: initialPane)
        )
    }

    @State private var scrubbing: Double?
    /// The row the words were centred on at the last draw, to tell a line
    /// sung into from a line jumped to. A slot index (`LyricSweep.slots`),
    /// not a line index: an interlude is a row, and comparing a slot against
    /// a line index would call the step out of every solo a seek.
    @State private var lastCentre: Int?
    /// How many rows the window held at the last draw. A window that changes
    /// size is a cut: see `isJump(from:to:windowFrom:to:)`.
    @State private var lastWindow: Int?
    @State private var outputs: [AudioOutputs.Output] = []
    @State private var currentOutput: AudioDeviceID?
    /// The volume bar's whole behaviour — the drag, the paced writes, the latch
    /// on the device a drag began on, mute — is `VolumeSliderModel`'s, shared
    /// with the player's slider since the redesign (spec §4.5). The card keeps
    /// only what is about the card: where the model is told a song changed, and
    /// whether there is a bar to draw.
    @StateObject private var volumeSlider: VolumeSliderModel

    /// Read through `@AppStorage` so changing it in Settings redraws the card
    /// while it is on screen, rather than at the next lock. Automatic when
    /// nothing is stored (spec §7.2); a stored choice is kept.
    @AppStorage(NotchViewModel.lockCardStyleKey) private var styleRaw = NotchViewModel.LockCardStyle.automatic.rawValue

    /// What the card is drawn in: Reduce Transparency makes every style Solid
    /// (`LockCardMaterial.effectiveStyle`), and otherwise the stored choice.
    private var style: NotchViewModel.LockCardStyle {
        LockCardMaterial.effectiveStyle(
            stored: NotchViewModel.LockCardStyle(rawValue: styleRaw) ?? .automatic,
            reduceTransparency: appearance.reduceTransparency
        )
    }

    private var glassRoute: (samplesBackdrop: Bool, preferDrawn: Bool, solid: Bool) {
        Self.glassRouting(
            style: style, hasArtwork: media.artwork != nil, reduceTransparency: appearance.reduceTransparency,
            increaseContrast: appearance.increaseContrast
        )
    }

    /// What the card is made of right now (spec §7.2): one pure decision of the
    /// style, whether there is a cover, the wallpaper's brightness and the two
    /// accessibility settings, read by the panel and the light alike.
    private var material: LockCardMaterial.Decision {
        LockCardMaterial.decision(
            style: style, hasArtwork: media.artwork != nil, luminance: tone.luminance,
            reduceTransparency: appearance.reduceTransparency, increaseContrast: appearance.increaseContrast
        )
    }

    /// The panel's colour when it is a panel: Solid's `#1C1C1E`, or Transparent's
    /// black 0.30.
    private var panelFill: Color? {
        material.layer == .blackWash ? Theme.lockCardTransparent(alpha: material.alpha) : Theme.lockCardSolid
    }

    @AppStorage(NotchViewModel.lockCardSizeKey) private var sizeRaw = NotchViewModel.LockCardSize.standard.rawValue

    private var cardSize: NotchViewModel.LockCardSize {
        NotchViewModel.LockCardSize(rawValue: sizeRaw) ?? .standard
    }

    /// The size the lock window is cut to, read when it is made. A setting
    /// changed mid-lock applies at the next lock: the window is never resized
    /// while it stands.
    static var size: CGSize { size(for: NotchViewModel.lockCardSize) }

    /// The window's card area: the largest thing the card ever is, 460 x 300 or
    /// 420 x 236 (it was 244 before the redesign). The banner is drawn inside it.
    static func size(for cardSize: NotchViewModel.LockCardSize) -> CGSize {
        LockCardLayout.canvas(cardSize)
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
    /// **Reduce Transparency is Solid, for every style** (spec §7.2): the
    /// surface already drew its opaque panel for the setting, but the cover's
    /// light was drawn over that panel regardless, so the card was not solid at
    /// all. `reduceTransparency` routes it to the panel and `body` draws no
    /// cover light for it.
    ///
    /// The `drawnGlass` default stays for the panel. It was the escape hatch
    /// for this card while the question was open, and the record closed it.
    ///
    /// **Transparent is a panel too** (spec §7.2: black at 0.30 and a hairline),
    /// so it routes to the same surface as Solid with a fill of its own — the
    /// drawn recipe's highlights and rim are not in the spec's description of it.
    static func glassRouting(
        style: NotchViewModel.LockCardStyle, hasArtwork: Bool, reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> (samplesBackdrop: Bool, preferDrawn: Bool, solid: Bool) {
        let layer = LockCardMaterial.decision(
            style: style, hasArtwork: hasArtwork, luminance: nil,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast
        ).layer
        let solid = layer == .solid || layer == .blackWash
        return (samplesBackdrop: !solid && !hasArtwork, preferDrawn: true, solid: solid)
    }

    /// How many lyric lines the middle shows. Odd, so the line being sung sits
    /// in the centre with the same amount of song either side of it.
    static let visibleLyricLines = 5

    static func visibleLyricLines(for cardSize: NotchViewModel.LockCardSize) -> Int {
        cardSize == .compact ? 3 : visibleLyricLines
    }

    // MARK: Output list

    /// One row of the output list is 36 pt: the 26 pt circle and 5 above and
    /// below it. Devices stand 36 pt apart, with nothing between the rows
    /// (spec §7.3) — it was 38 with a 2 pt gap before the redesign.
    static let outputRowHeight: CGFloat = LockCardLayout.outputRowPitch
    static let outputRowSpacing: CGFloat = 0

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

    /// How many whole rows fit between the list's top and the card's foot.
    /// Five on the standard card — the board's five devices — and three on the
    /// compact one, which is why a fixed five was never right.
    static func outputRowsThatFit(_ size: NotchViewModel.LockCardSize) -> Int {
        LockCardLayout.outputRowsThatFit(size)
    }

    /// The height of the scrolling list, for `count` devices.
    ///
    /// Up to the cap, exactly as tall as its rows. Past it, the last visible
    /// row is cut in half. The list scrolls without indicators — over the
    /// shield an overlay scroller only appears once someone is already
    /// scrolling — so a row sliced by the edge is the thing that says there is
    /// more below. A list that ended on a whole row would look complete.
    static func outputListHeight(count: Int, size: NotchViewModel.LockCardSize) -> CGFloat {
        LockCardLayout.outputListHeight(count: count, size)
    }

    /// The card tokens a picker row is drawn in.
    enum OutputInk: Equatable {
        case primary, cardTertiary, cardFill, accent

        @MainActor var color: Color {
            switch self {
            case .primary: return .white
            case .cardTertiary: return Theme.cardTertiary
            case .cardFill: return Theme.cardFill
            case .accent: return Theme.accent
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

    /// The selected device's circle is the owner's accent with a white glyph
    /// (spec §7.3, the macOS Sound module's own grammar), the others a faint
    /// neutral well with a quieter glyph — **and it also carries a trailing
    /// checkmark and a semibold name**, which the board does not draw.
    ///
    /// The accent used to be the *system's*, and white on a Yellow system accent
    /// is about 1.4:1, so the glyph vanished and the selection was told by
    /// colour alone (F-053). The accent here is the app's fixed red, which the
    /// white glyph clears, so that failure is gone; the checkmark and the weight
    /// stay anyway, because a stroke and a shape read the same under any
    /// wallpaper and any colour vision, and colour alone is the thing F-053
    /// said never to rely on.
    static func outputRowMarks(selected: Bool) -> OutputRowMarks {
        OutputRowMarks(
            checkmark: selected,
            semibold: selected,
            well: selected ? .accent : .cardFill,
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
            stage(track)
                .frame(width: dimensions.width, height: dimensions.height, alignment: .top)
                .environment(\.colorScheme, .dark)
                .onAppear {
                    readAudio()
                    presentation.size = cardSize
                }
                .onChange(of: cardSize) { _, now in presentation.size = now }
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
                    // The volume drag's end — the held level, the latch, the
                    // mirror — is the model's (`endForTrackChange`).
                    volumeSlider.endForTrackChange()
                    guard let now = media.track else { return }
                    Announcer.shared.announce(now.artist.isEmpty ? now.title : "\(now.title), \(now.artist)")
                }
                // The machine moves on its own while the card stands here — a
                // device connecting mid-lock, the volume keys — and the card used
                // to miss every bit of it until a pane switch re-read. The watch's
                // listeners speak for the card now; a finger on the bar owns the
                // level until release, so its mirror stands down while one drags.
                .onReceive(audio.$outputs) { outputs = $0 }
                .onReceive(audio.$current) { now in
                    // The default moving under a volume drag is the model's to
                    // handle (K-008); the card only follows it for its own list.
                    currentOutput = now
                }
                .transition(.opacity)
        }
    }

    /// The banner or the card, in the window's card area, top-centred.
    ///
    /// **The morph is one animation on one value.** `form` changes, and every
    /// frame below — the shape, the cover, the title, the artist, their sizes —
    /// is a function of it that SwiftUI interpolates on `Theme.lockCardMorph`,
    /// so the song's header travels. Under Reduce Motion nothing may travel
    /// (spec §13): the shape is given an identity of its own per form, so the
    /// banner dissolves and the card dissolves in over it, in place, on the
    /// 0.24 s crossfade. Everywhere else the identity is one constant and the
    /// frames glide.
    private func stage(_ track: MediaController.Track) -> some View {
        ZStack(alignment: .top) {
            shape(track)
                .id(reduceMotion ? form : LockCardLayout.Form.card)
                .transition(.opacity)
        }
        .frame(width: dimensions.width, height: dimensions.height, alignment: .top)
        .animation(Theme.lockCardMorph(reduceMotion: reduceMotion), value: form)
    }

    /// The visible shape: material, then the song's header, then whichever of
    /// the banner's ring or the card's body this form carries.
    private func shape(_ track: MediaController.Track) -> some View {
        let size = LockCardLayout.shapeSize(form, cardSize)
        let radius = LockCardLayout.shapeRadius(form, cardSize)
        return ZStack(alignment: .topLeading) {
            // Under everything, so the cover, the title and the artist — none of
            // which take a click — let a press fall through to it; the ring, above,
            // keeps its own.
            if form == .banner {
                bannerTarget(track).transition(.opacity)
            }
            headerLayer(track)
            if form == .banner {
                ring.transition(.opacity.animation(Theme.paneIn))
            }
            if form == .card {
                cardBody
                    .transition(.asymmetric(
                        insertion: .opacity.animation(Theme.paneIn),
                        removal: .opacity.animation(Theme.paneOut)
                    ))
            }
        }
        // Every mark on the card carries its own shadow on glass. That is
        // how white type survives a bright wallpaper without a scrim
        // painting the wallpaper out — the system does the same on its own
        // lock screen, and it is why the clock there is readable over
        // anything.
        // More of the wallpaper shows through Transparent, so its type
        // carries more shadow to stay legible over it. Keyed off the layer that
        // is drawn, not the stored style (re-review 2026-10-15).
        .shadow(color: .black.opacity(LockCardMaterial.textShadowOpacity(for: material.layer)), radius: 3, y: 1)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background { coverLight(size: size) }
        .glassSurface(
            cornerRadius: radius,
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
            solid: glassRoute.solid,
            solidFill: panelFill
        )
        // No drop shadow. The system's own lock player has none — the
        // material defines its own edge, and a card floating on a drawn
        // shadow reads as a sticker laid on the wallpaper rather than a
        // pane set into it. These were a contact shadow and a wide soft
        // one; clipped square by a window with no margin they were the
        // dark rectangle behind the corners, and given room to fall they
        // were simply a halo Apple does not draw.
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
    ///
    /// Its opacity is the material (`LockCardMaterial.decision`): Automatic draws
    /// it at the alpha the wallpaper behind the card asks for
    /// (`LockCardMaterial.automaticAlpha`, never under 0.84), Tinted at 0.88; the
    /// spec's Transparent is not the cover's light at all but black at 0.30. It is
    /// drawn at the size of the shape — the banner's or the card's — so it grows
    /// with it.
    @ViewBuilder
    private func coverLight(size: CGSize) -> some View {
        let decision = material
        if decision.layer == .neutralFill {
            // No cover to light the card from: the same opacity on a dark neutral
            // (review 2026-10-15), so Automatic keeps its 0.84 floor for a podcast
            // or a browser tab instead of being the bare recipe over the shield.
            Theme.lockCardSolid
                .frame(width: size.width, height: size.height)
                .opacity(decision.alpha)
                .accessibilityHidden(true)
        } else if decision.layer == .coverLight, let image = media.artwork {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    // Oversized before the blur, so the blur has no soft,
                    // darker rim to show at the card's edge. The zoom is
                    // `LockCardLegibility`'s, because its measurement of the
                    // cover crops to exactly what this leaves showing.
                    .scaleEffect(LockCardLegibility.coverZoom)
                    .blur(radius: 44, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(LockCardLegibility.washOpacity(
                    coverLuma: LockCardLegibility.coverLuma(of: image),
                    increaseContrast: appearance.increaseContrast
                ))
                LinearGradient(
                    colors: [.clear, .black.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: size.width, height: size.height)
            // Automatic and Tinted let a little of the wallpaper through the
            // cover's light (no window above the shield is given a backdrop to
            // blur, so this is as much glass as the card can be), never under
            // the 0.84 floor of Automatic.
            .opacity(decision.alpha)
            .clipped()
            // Light, not a picture: blurred past recognition on purpose, it was
            // read as a nameless 690x690 image (H-009). The cover the listener
            // can name is the one in the header.
            .accessibilityHidden(true)
            // With Reduce Motion on too. The light only changes colour and
            // brightness under a skip — nothing in it moves — and it used to
            // cut there, so the whole card behind the type changed in one
            // frame, the most abrupt thing on the lock screen for the people
            // who asked for calm. A fade is not motion (F-055).
            .animation(Theme.artworkAnimation, value: media.artwork)
        }
    }

    // MARK: - The song's header: cover, title, artist

    /// Cover, title and artist at the frames `LockCardLayout.header` gives the
    /// current form and pane. They are in every form and every pane but the
    /// Output pane's, and their frames are what travel: banner to card, player to
    /// lyrics. None of them takes a click.
    private func headerLayer(_ track: MediaController.Track) -> some View {
        let header = LockCardLayout.header(form, pane: pane, cardSize)
        let width = LockCardLayout.titleWidth(form, pane: pane, cardSize, hasHeart: showsHeart)
        return ZStack(alignment: .topLeading) {
            cover(side: header.cover.width, radius: header.coverRadius)
                .offset(x: header.cover.minX, y: header.cover.minY)
            Text(track.title)
                .modifier(MorphingFont(size: header.titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .offset(x: header.title.x, y: header.title.y)
            Text(track.artist)
                .modifier(MorphingFont(size: header.artistSize, weight: .regular))
                .foregroundStyle(Theme.cardSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .offset(x: header.artist.x, y: header.artist.y)
        }
        .opacity(header.visible ? 1 : 0)
        .animation(Theme.contentAnimation, value: header.visible)
        .allowsHitTesting(false)
        // Hidden on the banner too (review 2026-10-15): there the song is the
        // banner button's label ("title, artist"), and the two text elements
        // beside it made VoiceOver read the song twice.
        .accessibilityHidden(!header.visible || form == .banner)
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

    /// A font whose size is interpolated, so the title can go from the banner's
    /// 13 to the card's 16 with the frame it travels in. SwiftUI animates a
    /// `Font` only by swapping it; an `Animatable` size rebuilds it every frame,
    /// with the tracking that size wants.
    private struct MorphingFont: ViewModifier, Animatable {
        var size: CGFloat
        let weight: Font.Weight

        var animatableData: CGFloat {
            get { size }
            set { size = newValue }
        }

        func body(content: Content) -> some View {
            content
                .font(.system(size: size, weight: weight))
                .tracking(Theme.tracking(forSize: size))
        }
    }

    /// The cover, at whatever side the form and pane ask. A cover's corner, not
    /// an app icon's: the radius is the board's — 10 on the banner and the card
    /// (concentric with their 22 and 30 at a 12 and a 20 inset), 8 on the
    /// lyrics pane's small one.
    private func cover(side: CGFloat, radius: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
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
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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
            //
            // Only on the player's big cover: a 40 pt banner cover or the lyrics
            // pane's 34 pt one has no corner to spare for it.
            sourceBadge
                .offset(x: 4, y: 4)
                .opacity(side >= 60 ? 1 : 0)
                .accessibilityHidden(side < 60)
        }
        .frame(width: side, height: side)
    }


    // MARK: - The banner

    /// The banner's whole face is one target: a click anywhere on it but the ring
    /// grows it into the card. A clear layer under the header, which takes no
    /// clicks of its own, so the press lands here; the ring is a button above it
    /// and keeps its own. VoiceOver finds the banner as one button, named for the
    /// song, whose action opens the card.
    private func bannerTarget(_ track: MediaController.Track) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { presentation.expand() }
            .accessibilityElement()
            .accessibilityLabel(track.artist.isEmpty ? track.title : "\(track.title), \(track.artist)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { presentation.expand() }
    }

    /// Play/pause inside a 34 pt ring that is the progress bar: a track at the
    /// card's quiet white, the progress in white, 2 pt, round-capped, starting at
    /// 12 o'clock (spec §7.1). It tells how far through the song it is and
    /// nothing more — seeking is the card's — so the ring itself takes no drag.
    private var ring: some View {
        let frame = LockCardLayout.ring
        return Button { media.togglePlayPause() } label: {
            ZStack {
                Circle()
                    .inset(by: 1.5)
                    .stroke(Theme.cardTrack, lineWidth: LockCardLayout.ringLineWidth)
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: LockCardLayout.ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .islandFont(.subhead)
                    .foregroundStyle(.white)
                    .symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)
            }
            .frame(width: frame.width, height: frame.height)
            .contentShape(Circle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(media.isPlaying ? localized("Pause") : localized("Play"))
        .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - The card

    /// The card's body: whichever pane is up, faded in after the shape has grown.
    private var cardBody: some View {
        ZStack(alignment: .topLeading) {
            switch pane {
            case .player: playerBody.transition(paneFade)
            case .lyrics: lyricsBody.transition(paneFade)
            case .output: outputBody.transition(paneFade)
            }
        }
        .frame(width: dimensions.width, height: dimensions.height, alignment: .topLeading)
        // A fade is not motion, and the setting never asked for it to go: the
        // panes dissolve on the content curve either way (F-055).
        .animation(Theme.contentAnimation, value: pane)
    }

    private var paneFade: AnyTransition { .opacity }

    /// The 24 pt button at the card's top right: Collapse on the player,
    /// Back to Player on the other two. Its glyph is a 10 pt semibold chevron on
    /// the card's quiet fill.
    private func chevronButton(
        symbol: String, label: String, on target: Pane, action: @escaping () -> Void
    ) -> some View {
        let frame = LockCardLayout.chevron(pane: target, cardSize)
        return Button(action: action) {
            Image(systemName: symbol)
                .islandFont(.caption, weight: .semibold)
                .foregroundStyle(Theme.cardSecondary)
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(Theme.cardFill))
                .contentShape(Circle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - The player pane

    private var playerBody: some View {
        let showsBar = Self.showsSeekBar(duration: media.duration)
        return ZStack(alignment: .topLeading) {
            // Only a card that rests as a banner has one to fold back into; with
            // Rest as Banner off the card shows directly and has no chevron.
            if presentation.showsCollapse {
                chevronButton(
                    symbol: "chevron.up", label: localized("Collapse"), on: .player,
                    action: { presentation.collapse() }
                )
            }
            heart.placed(LockCardLayout.heart(cardSize))
            sungLine
            // Hidden in place rather than removed: the card's layout is fixed
            // by design, and taking the bar out of the stack would let the
            // spacers close over it and move the transport a stream away from
            // where it sits for a song. `hidden()` keeps the bar's size and
            // takes it out of drawing, hit testing and VoiceOver at once.
            // Opacity with `accessibilityHidden(true)` was tried first and
            // left the slider and its "0:00" in reading order: an outer
            // `false` wins over an inner `true` (measured in
            // LockCardAccessibilityTests).
            if showsBar {
                seekRow.placed(LockCardLayout.progress(cardSize))
            } else {
                seekRow.hidden().placed(LockCardLayout.progress(cardSize))
            }
            transport.placed(LockCardLayout.transport(cardSize))
            rail.placed(LockCardLayout.footer(cardSize))
        }
    }

    /// Whether the seek bar is drawn for a track of this length.
    ///
    /// A live stream or a browser tab reports no length, and the card drew a
    /// full-width bar reading 0:00 / -0:00 whose drags were all refused by the
    /// guards in its own gesture (F-031) — a control that looked broken rather
    /// than absent, while the panel already hid its scrubber in that state.
    /// A length that is not finite cannot place a seek either.
    static func showsSeekBar(duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0
    }

    /// The line being sung, set where the board puts it (20, 104), with its
    /// translation under it at (20, 125) when Translate Lyrics is on and the
    /// batch has landed. Nothing at all when there are no synced lyrics: the
    /// banner-sized gap is the card's honest answer, and the Lyrics pane is
    /// where the reason is told. Not on the compact card, which is the standard
    /// card without its lyric.
    @ViewBuilder
    private var sungLine: some View {
        if let origin = LockCardLayout.lyric(cardSize),
           case .ready = lyrics.availability,
           case .synced(let lines) = lyrics.state,
           !lines.isEmpty {
            let resolution = Self.resolve(lines: lines, inputs: lyricInputs)
            let slots = LyricSweep.slots(for: lines)
            let centre = LyricSweep.slotIndex(of: resolution.moment.centreSlot, in: slots)
            let lit = LyricSweep.litSlotIndex(resolution.moment, in: slots)
            if case .line(let index) = slots[centre] {
                let rows = translation.displayRows(for: lines)
                VStack(alignment: .leading, spacing: LyricRow.translationGap) {
                    lyricRow(
                        lines: lines, index: index, resolution: resolution,
                        distance: LyricSweep.distance(ofSlot: centre, lit: lit), lineLimit: 1,
                        displaysText: Self.bilingualPrimary(lines[index])
                    )
                    if let text = rows[index] {
                        translationText(text, sung: true)
                    }
                }
                .frame(width: LockCardLayout.progress(cardSize).width, alignment: .leading)
                .offset(x: origin.x, y: origin.y)
            }
        }
    }

    /// A translation under a lyric line: the sung line's a step larger and
    /// brighter (spec §7.1: 11.5 / medium on the player, 12.5 on the Lyrics
    /// pane), the others' quieter. In the card's own greys — never a raw opacity.
    private func translationText(_ text: String, sung: Bool) -> some View {
        Text(text)
            .islandFont(sung ? .reading : .body, weight: sung ? .medium : .regular)
            .foregroundStyle(sung ? Theme.cardSecondary : Theme.cardTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    private var lyricInputs: LyricInputs {
        LyricInputs(
            position: media.position,
            precisionSync: media.precisionSync,
            userOffset: lyrics.userOffset,
            trackOffset: lyrics.trackOffset,
            wordTiming: wordTimingEnabled
        )
    }

    // MARK: - The Lyrics pane

    private var lyricsBody: some View {
        ZStack(alignment: .topLeading) {
            chevronButton(
                symbol: "chevron.left", label: localized("Back to Player"), on: .lyrics,
                action: { pane = .player }
            )
            lyricsRows
                .placed(LockCardLayout.lyricsArea(cardSize), alignment: .topLeading, clipped: true)
            lyricsFooter
        }
    }

    /// The words: a window of the song centred on the line being sung, with each
    /// line's translation under it when there are translations.
    ///
    /// A fixed window of lines rather than a scroll view: the card cannot grow,
    /// and a scroller inside a surface that answers clicks above the login
    /// shield is one more thing to get wrong there. Clicking a line seeks to it,
    /// exactly as it does on the full stage.
    ///
    /// Plain, it holds what it always held, five lines (three compact) and the
    /// sung line may wrap to a second row when it must (H-019). With
    /// translations it is the board's four (two compact): one line before the
    /// sung one and two after, each with its translation under it, and the sung
    /// line on a single row — a wrapped sung line and a translation under it do
    /// not both fit the room the board leaves.
    private var lyricsRows: some View {
        Group {
            if case .ready = lyrics.availability,
               case .synced(let lines) = lyrics.state,
               !lines.isEmpty {
                let resolution = Self.resolve(lines: lines, inputs: lyricInputs)
                // The window is over slots, not lines: through a solo the
                // middle row is the interlude marker, filling toward the line
                // below it. Everything that counts rows here — `centre`,
                // `lastCentre`, the window and the jump test — counts slots,
                // so singing into an interlude and out of it is two steps of
                // one row, never a seek.
                let slots = LyricSweep.slots(for: lines)
                let centre = LyricSweep.slotIndex(of: resolution.moment.centreSlot, in: slots)
                let lit = LyricSweep.litSlotIndex(resolution.moment, in: slots)
                let translations = translation.displayRows(for: lines)
                let translated = LyricTranslation.hasRows(translations)
                // The centre row may take two lines when its line needs them
                // (H-019), and the window narrows to pay for it. The centre
                // line, not the sung one: through an intro the opening line
                // waits in the centre unsung, and it is the row the window is
                // laid around either way. An interlude marker is one row.
                let centreLine: Int? = {
                    if case .line(let index) = slots[centre] { return index }
                    return nil
                }()
                let layout: LyricLayout = translated
                    ? LyricLayout(
                        window: LockCardLayout.lyricRowCount(cardSize, translated: true),
                        currentLineLimit: 1
                    )
                    : Self.lyricLayout(
                        currentText: centreLine.map { lines[$0].text },
                        width: Self.lyricTextWidth(for: cardSize),
                        cardSize: cardSize
                    )
                let window = Self.window(around: centre, count: slots.count, size: layout.window)
                let jump = Self.isJump(from: lastCentre, to: centre, windowFrom: lastWindow, to: layout.window)
                VStack(alignment: .leading, spacing: translated ? 0 : Self.lyricRowSpacing) {
                    ForEach(window, id: \.self) { position in
                        Group {
                            switch slots[position] {
                            case .line(let index):
                                let sung = position == lit
                                VStack(alignment: .leading, spacing: LyricRow.translationGap) {
                                    lyricRow(
                                        lines: lines, index: index, resolution: resolution,
                                        distance: LyricSweep.distance(ofSlot: position, lit: lit),
                                        lineLimit: index == centreLine ? layout.currentLineLimit : 1,
                                        displaysText: Self.bilingualPrimary(lines[index])
                                    )
                                    if translated, let text = translations[index] {
                                        translationText(text, sung: sung)
                                    }
                                }
                                .frame(
                                    height: translated ? Self.translatedRowHeight(sung: sung) : nil,
                                    alignment: .top
                                )
                            case .interlude:
                                interludeRow(
                                    slots[position], resolution: resolution,
                                    distance: LyricSweep.distance(ofSlot: position, lit: lit)
                                )
                                .frame(
                                    height: translated ? Self.translatedRowHeight(sung: position == lit) : nil,
                                    alignment: .top
                                )
                            }
                        }
                        .transition(Self.lineTransition(
                            reduceMotion: reduceMotion,
                            travel: translated ? LockCardLayout.translatedLyricPitch : Self.lineTravel
                        ))
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
                // a line reached by clicking is simply there. So is a line that
                // changes the window's size, for the same reason.
                .transaction { transaction in
                    if jump {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .onChange(of: centre) { _, now in lastCentre = now }
                .onChange(of: layout.window) { _, now in lastWindow = now }
                .onAppear {
                    lastCentre = centre
                    lastWindow = layout.window
                }
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

    /// A bilingual file's first row, drawn as the line itself while its second is
    /// the translation (`LyricRow.displayText`); nil for every ordinary line.
    private static func bilingualPrimary(_ line: LyricsStore.Line) -> String? {
        let rows = LyricTranslation.rows(of: line.text)
        return rows.secondary == nil ? nil : rows.primary
    }

    /// The height of a translated row: the board's 44, and 54 for the sung one,
    /// whose translation is the larger. What the window's pitch is made of.
    static func translatedRowHeight(sung: Bool) -> CGFloat {
        LockCardLayout.translatedLyricPitch + (sung ? LockCardLayout.translatedSungExtra : 0)
    }

    /// The Lyrics pane's foot: Hide Lyrics in its selected look, the seek row
    /// 300 wide, and the small transport — previous, play/pause, next.
    private var lyricsFooter: some View {
        let footer = LockCardLayout.footer(cardSize)
        return ZStack(alignment: .topLeading) {
            paneButton(
                .lyrics, symbol: "quote.bubble.fill", label: localized("Hide Lyrics")
            )
            .placed(CGRect(x: footer.minX, y: footer.minY, width: LockCardLayout.footerButton, height: LockCardLayout.footerButton))
            seekRow.placed(LockCardLayout.lyricsFooterProgress(cardSize))
            smallTransport.placed(LockCardLayout.lyricsTransport(cardSize))
        }
    }

    private var smallTransport: some View {
        HStack(spacing: 2) {
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").islandFont(.subhead)
            }
            .buttonStyle(TransportGlyphStyle(size: 24))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Previous Track"))
            .accessibilityLabel(localized("Previous Track"))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .islandFont(.title)
                    .symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)
            }
            .buttonStyle(TransportGlyphStyle(size: 24))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Button { media.next() } label: {
                Image(systemName: "forward.fill").islandFont(.subhead)
            }
            .buttonStyle(TransportGlyphStyle(size: 24))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Next Track"))
            .accessibilityLabel(localized("Next Track"))
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

    /// - Parameter displaysText: what to draw as the line itself when a bilingual
    ///   file's first row is the line and its second the translation.
    private func lyricRow(
        lines: [LyricsStore.Line], index: Int, resolution: LyricResolution, distance: Int, lineLimit: Int,
        displaysText: String? = nil
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
            // One row, except the centre line when `lyricLayout` gave it two.
            lineLimit: lineLimit,
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
            },
            displayText: displaysText
        )
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


    // MARK: - The Output pane: the macOS Sound module

    /// Where the sound goes, presented the way macOS presents it in its own Sound
    /// module — not a sheet over the player with a now-playing header (spec
    /// §7.3): "Sound" and a Back chevron, the system volume on a slider with an
    /// 8 pt track and a knob, and under an "Output" heading the devices as 26 pt
    /// circles, the playing one in the accent, 36 pt apart.
    ///
    /// It used to be a popover opened over the player under a dimming scrim, so
    /// what was playing stayed visible behind the thing choosing where it plays.
    /// The board drops the player altogether, and with it the scrim and the
    /// glass-on-glass the scrim existed to prevent. Control Center's list is
    /// still the reference for the rows; the selected row's departure from it is
    /// `outputRowMarks`.
    private var outputBody: some View {
        ZStack(alignment: .topLeading) {
            Text(localized("Sound"))
                .islandFont(.title, weight: .semibold)
                .foregroundStyle(.white)
                .offset(x: LockCardLayout.outputTitle.x, y: LockCardLayout.outputTitle.y)
            chevronButton(
                symbol: "chevron.left", label: localized("Back to Player"), on: .output,
                action: { pane = .player }
            )
            if volumeSlider.volume != nil {
                // The system's output volume, the same model the foot rail's bar
                // and the player's drive. Absent entirely for a device that has
                // none to give, rather than a slider that moves and changes
                // nothing.
                SystemVolumeSlider(model: volumeSlider, look: .sound)
                    .placed(LockCardLayout.outputVolume(cardSize))
            }
            Text(localized("Output"))
                .islandFont(.body, weight: .semibold)
                .foregroundStyle(Theme.cardSecondary)
                .offset(x: LockCardLayout.outputHeading.x, y: LockCardLayout.outputHeading.y)

            if outputs.isEmpty {
                Text(localized("No output devices."))
                    .islandFont(.subhead, weight: .regular)
                    .foregroundStyle(Theme.cardTertiary)
                    .offset(x: 20, y: LockCardLayout.outputListTop + 5)
            } else {
                // Every device, the current one first, in a list that scrolls
                // rather than grows: past what fits above the card's foot it
                // would be cut by the window. `.basedOnSize` keeps a short list
                // from rubber-banding as if it had somewhere to go.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Self.outputRowSpacing) {
                        ForEach(Self.orderedOutputs(outputs, current: currentOutput)) { device in
                            outputRow(device)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    width: dimensions.width,
                    height: Self.outputListHeight(count: outputs.count, size: cardSize)
                )
                .offset(y: LockCardLayout.outputListTop)
            }
        }
        // One named group, the way the list was when it was a popover: "Sound
        // Output", the control's own name, holding the devices (H-010), with
        // Escape — VoiceOver's way out of a modal, and the card's own — going
        // back to the player.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Sound Output"))
        .accessibilityAction(.escape) { pane = .player }
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
            // The pane stays up, as the system's Sound module does: the accent
            // moving to the row just chosen is the answer, and the volume row
            // above now shows the new device's level.
            readAudio()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(marks.well.color)
                        .frame(width: LockCardLayout.outputCircle, height: LockCardLayout.outputCircle)
                    Image(systemName: device.symbol)
                        .islandFont(.body)
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
            // 12 here and the row style's own 8 put the circle at x 20, where
            // the board has it.
            .padding(.horizontal, 12)
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

    /// The seek row of the board: the elapsed time, the bar, what is left, on one
    /// line (12 pt tall) where it used to be a bar over its two labels.
    private var seekRow: some View {
        HStack(spacing: 8) {
            Text(formatTime(shownElapsed))
                .frame(minWidth: 26, alignment: .leading)
                .fixedSize()
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardTrack).frame(height: 4)
                    Capsule().fill(accent.opacity(0.9)).frame(width: width * fraction, height: 4)
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
            // 22 pt to grab inside the 12 pt the row lays out, as the panel's
            // scrubber does (F-014): the bar is drawn the same, and a finger that
            // lands a little high or low still seeks.
            .frame(height: 22)
            // The same slider the panel's scrubber is: over the lock screen
            // this is the only way to move the song without a pointer.
            .playbackPositionAccessibility(
                shown: fraction * media.duration,
                duration: media.duration,
                position: { media.position },
                seek: { media.seek(to: $0) }
            )
            // What is left, which is the question a lock screen gets asked:
            // how long until this is over.
            Text("-" + formatTime(max(0, media.duration - shownElapsed)))
                .frame(minWidth: 30, alignment: .trailing)
                .fixedSize()
        }
        // Small and quiet, as the system sets a player's times: they are
        // read in passing, and bold numerals at the body size shouted over
        // the song they belong to.
        .font(Theme.TypeRole.caption.font(weight: .medium).monospacedDigit())
        .tracking(Theme.tracking(forSize: Theme.TypeRole.caption.size))
        .foregroundStyle(Theme.cardTertiary)
        .frame(height: 12)
    }

    /// Previous, play and next, centred — and nothing else.
    ///
    /// A lock screen's player carries the three and leaves shuffle and repeat
    /// to the app: they are settings, not transport, and Apple's own lock
    /// players have never set them from there. Pinned to the card's two ends
    /// they made the row read as an app's toolbar rather than the system's
    /// player. They stay in the panel, where the rest of the app is.
    ///
    /// 160 x 36 at the board's place: three 36 pt targets with the glyphs at
    /// 20, 26 and 20 pt (the display and hero roles, the nearest the type scale
    /// has).
    private var transport: some View {
        HStack(spacing: 0) {
            Button { media.previous() } label: {
                Image(systemName: "backward.fill").islandFont(.display)
            }
            .buttonStyle(TransportGlyphStyle(size: 36))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Previous Track"))
            .accessibilityLabel(localized("Previous Track"))
            Spacer(minLength: 0)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .islandFont(.hero)
                    .symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)
            }
            .buttonStyle(TransportGlyphStyle(size: 36))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            Spacer(minLength: 0)
            Button { media.next() } label: {
                Image(systemName: "forward.fill").islandFont(.display)
            }
            .buttonStyle(TransportGlyphStyle(size: 36))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
            .help(localized("Next Track"))
            .accessibilityLabel(localized("Next Track"))
        }
    }

    /// The foot rail: the words, the level, and where the sound goes.
    ///
    /// The Music app's player keeps its lyrics door and its output picker at
    /// its foot, with the volume between them, and so does this. The volume
    /// used to sit between the scrubber and the transport, where no Apple
    /// player puts it. 28 pt buttons at each end and the slider between, 40 in
    /// from each edge of the rail (spec §7.1).
    private var rail: some View {
        HStack(spacing: 0) {
            paneButton(.lyrics, symbol: "quote.bubble", label: localized("Lyrics"))
            if volumeSlider.volume != nil {
                // The system's output volume. Absent entirely for a device that
                // has none to give, rather than a slider that moves and changes
                // nothing.
                SystemVolumeSlider(model: volumeSlider, look: .card)
                    .padding(.horizontal, 12)
            } else {
                Spacer(minLength: 0)
            }
            paneButton(
                .output, symbol: outputSymbol, label: localized("Sound Output"),
                value: Self.outputName(outputs: outputs, current: currentOutput)
            )
        }
        .frame(height: LockCardLayout.footerButton)
    }

    /// What the open pane's door wears behind its glyph. The open glyph used to
    /// differ from its bare sibling by one opacity step, white against
    /// `cardSecondary`, which a pale cover or low vision cannot tell apart
    /// (M-17): a filled well says "this one is open" as a shape, and Increase
    /// Contrast adds the card's hairline edge to it. The siblings stay bare.
    struct PaneButtonLook: Equatable {
        let wellOpacity: Double
        let outlined: Bool
    }

    static func paneButtonLook(open: Bool, increaseContrast: Bool) -> PaneButtonLook {
        guard open else { return PaneButtonLook(wellOpacity: 0, outlined: false) }
        return PaneButtonLook(
            wellOpacity: Theme.cardFillOpacity(increaseContrast: increaseContrast),
            outlined: increaseContrast
        )
    }

    /// The name of the device the sound goes to, for the output button's value:
    /// the button is a glyph, and a locked-Mac user could not tell where the
    /// sound goes without opening the picker (M-24). Nil for a device the list
    /// does not hold, so the button then says only what it is.
    static func outputName(outputs: [AudioOutputs.Output], current: AudioDeviceID?) -> String? {
        guard let current else { return nil }
        return outputs.first(where: { $0.id == current })?.name
    }

    private func paneButton(
        _ target: Pane, symbol: String, label: String, value: String? = nil
    ) -> some View {
        let open = pane == target
        let look = Self.paneButtonLook(open: open, increaseContrast: appearance.increaseContrast)
        return Button {
            pane = open ? .player : target
        } label: {
            Image(systemName: symbol)
                .islandFont(.subhead, weight: .medium)
                .foregroundStyle(open ? Color.white : Theme.cardSecondary)
                // The output glyph follows the route, which moves when a
                // device is picked or unplugged — never in an animation.
                .symbolSwap(value: symbol, reduceMotion: reduceMotion)
                .frame(width: LockCardLayout.footerButton, height: LockCardLayout.footerButton)
                .background {
                    // The board's 28 pt round button, the rail's own height.
                    Circle()
                        .fill(Color.white.opacity(look.wellOpacity))
                        .overlay {
                            if look.outlined {
                                Circle().strokeBorder(Theme.cardHairline, lineWidth: 1)
                            }
                        }
                        .frame(width: LockCardLayout.footerButton, height: LockCardLayout.footerButton)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(value.map { "\(label), \($0)" } ?? label)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(open ? [.isSelected] : [])
    }

    private var outputSymbol: String {
        AudioOutputs.symbol(outputs: outputs, current: currentOutput, fallback: "airplayaudio")
    }

    /// Whether the heart is drawn: Spotify connected, the account answering and
    /// the song a Spotify one.
    private var showsHeart: Bool {
        spotify.isConnected && !spotify.apiBlocked && !spotify.tokenUnavailable && media.spotifyTrackID != nil
    }

    private var heart: some View {
        Group {
            if showsHeart, let id = media.spotifyTrackID {
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
                        .symbolSwap(value: isSaved, reduceMotion: reduceMotion)
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

    /// One row of lyric type: the title role's 16pt bold, which lays out 19pt
    /// tall. `LockCardLyricGlideTests` measures it.
    static let lyricLineHeight: CGFloat = 19
    /// The spacing of the window's stack, between one row and the next.
    static let lyricRowSpacing: CGFloat = 7

    /// How far a line travels entering or leaving the window: one row of the
    /// title role plus the stack's spacing, so the leaving line moves exactly
    /// as far as the lines behind it and the arriving one starts where the
    /// next row would have been. The page moves as one.
    static let lineTravel: CGFloat = lyricLineHeight + lyricRowSpacing

    /// The card's side padding, which is all that stands between its edge and
    /// the lyric rows: they span the rest.
    ///
    /// 20 on both cards since the redesign (it was 24 on the standard one): the
    /// board's every row, the sung line, the scrubber and the footer, starts 20
    /// in from the edge.
    static func horizontalPadding(for cardSize: NotchViewModel.LockCardSize) -> CGFloat {
        20
    }

    /// The width a lyric row has to set its line in: 420pt on the standard
    /// card, 380pt on the compact one.
    static func lyricTextWidth(for cardSize: NotchViewModel.LockCardSize) -> CGFloat {
        size(for: cardSize).width - 2 * horizontalPadding(for: cardSize)
    }

    /// How many rows the window shows, and how many lines the centre row may
    /// take.
    struct LyricLayout: Equatable {
        var window: Int
        var currentLineLimit: Int
    }

    /// The window for one centre line: the plain one while that line fits a
    /// row, and a narrower one around a two-row line when it does not.
    ///
    /// Every row used to be one line, the line being sung included, so on the
    /// lock screen a long line read "…past the point wh…" while the stage
    /// beside it wrapped the same line whole (H-019) — the surface with the
    /// least room was the one that knew least, and the line cut was the one
    /// being sung. Now the centre row takes the stage's second row, and the
    /// window gives up a neighbour each side to pay for it, so the card's
    /// middle never asks for more than it already had:
    ///
    /// - standard, plain: 5 rows × 19 + 4 gaps × 7 = 123pt, in a middle
    ///   measured at 126pt. Wrapped, five rows would be 6 lines × 19 + 4 × 7
    ///   = 142pt; three are 4 lines × 19 + 2 × 7 = 90pt, which fits.
    /// - compact, plain: 3 × 19 + 2 × 7 = 71pt in a middle of 84pt. Wrapped,
    ///   three rows are the same 90pt, too tall, so the sung line stands
    ///   alone on its two rows, 38pt.
    ///
    /// The window stays odd, so the sung line keeps the centre. Neither a
    /// scroll view (see `lyricsPane`: not above the shield) nor a smaller font
    /// (the rows share the title role with the card's title) was the answer.
    static func lyricLayout(
        currentText: String?, width: CGFloat, cardSize: NotchViewModel.LockCardSize
    ) -> LyricLayout {
        let plain = LyricLayout(window: visibleLyricLines(for: cardSize), currentLineLimit: 1)
        guard let currentText, measureLyricLine(currentText) > width else { return plain }
        let room = lyricStackHeight(plain)
        var window = plain.window
        while window > 1, lyricStackHeight(LyricLayout(window: window, currentLineLimit: 2)) > room {
            window -= 2
        }
        return LyricLayout(window: window, currentLineLimit: 2)
    }

    /// The height a window of rows lays out at, its centre row at its limit.
    static func lyricStackHeight(_ layout: LyricLayout) -> CGFloat {
        let lines = layout.window - 1 + layout.currentLineLimit
        return CGFloat(lines) * lyricLineHeight + CGFloat(max(layout.window - 1, 0)) * lyricRowSpacing
    }

    /// The width a lyric line takes on one unbroken row, set exactly as
    /// `KaraokeText` sets the sung line: the system font at the title role's
    /// size, bold, with that size's tracking. A different font or tracking
    /// here and the decision would disagree with the wrap — a line measured
    /// as fitting would be cut by a one-row limit, or a line that fits would
    /// cost two neighbours for nothing. `LockCardPaneTests` holds the two
    /// together against the drawn row.
    ///
    /// Asked on every draw, and the card draws on every clock tick, so the
    /// last answer is kept: the centre line changes a few times a minute.
    static func measureLyricLine(_ text: String) -> CGFloat {
        if let measuredLine, measuredLine.text == text { return measuredLine.width }
        let size = Theme.TypeRole.title.size
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .kern: Theme.tracking(forSize: size),
        ]
        let width = NSAttributedString(string: text, attributes: attributes).size().width
        measuredLine = (text, width)
        return width
    }

    private static var measuredLine: (text: String, width: CGFloat)?

    /// - Parameter travel: how far a line moves entering or leaving: one row of
    ///   the window, which with translations under the lines is the board's 44
    ///   rather than the plain 26.
    static func lineTransition(reduceMotion: Bool, travel: CGFloat = lineTravel) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: travel)),
            removal: .opacity.combined(with: .offset(y: -travel))
        )
    }

    /// Whether the centre moved by more than one line: a seek, not singing.
    static func isJump(from previous: Int?, to centre: Int) -> Bool {
        guard let previous else { return false }
        return abs(centre - previous) > 1
    }

    /// The same, counting a window that changed size as a jump. Singing into
    /// a two-row line narrows the window from five rows to three, and out of
    /// it widens it again; glided, every row would travel `lineTravel` against
    /// a row pitch that had just changed under it and land between slots. So
    /// those turns are a cut, like a seek — the price of the sung line being
    /// whole.
    static func isJump(from previous: Int?, to centre: Int, windowFrom previousWindow: Int?, to window: Int) -> Bool {
        if let previousWindow, previousWindow != window { return true }
        return isJump(from: previous, to: centre)
    }

    /// A window of `size` indices centred on `centre`, slid inside the song
    /// rather than clipped at its ends — so the first and last lines still show
    /// a full card of words instead of a half-empty one.
    ///
    /// The sung line has `LockCardLayout.rowsBefore(count:)` rows above it: the
    /// middle of an odd window, and — for the board's four translated lines —
    /// one above and two below, because a window of an even number of rows has
    /// no middle and the song reads better with the next lines in view than the
    /// last ones.
    static func window(around centre: Int, count: Int, size: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > size else { return Array(0..<count) }
        let before = LockCardLayout.rowsBefore(count: size)
        let start = min(max(centre - before, 0), count - size)
        return Array(start..<(start + size))
    }
}

private extension View {
    /// At `rect` in the coordinates of the shape it is laid in: a frame of its
    /// size, moved to its origin. The card's elements are placed, not stacked, so
    /// every frame the board gives is the one the test holds
    /// (`LockCardLayout`). Clipped *before* it is moved, because a clip follows
    /// the layout frame and an offset does not move it.
    func placed(_ rect: CGRect, alignment: Alignment = .center, clipped: Bool = false) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .modifier(OptionalClip(clipped: clipped))
            .offset(x: rect.minX, y: rect.minY)
    }
}

private struct OptionalClip: ViewModifier {
    let clipped: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if clipped { content.clipped() } else { content }
    }
}

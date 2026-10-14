import CoreGraphics
import SwiftUI

/// Where everything on the lock banner and the lock card goes (redesign
/// 2026-10-15, spec §7.1 and §7.3), as numbers.
///
/// **One object, two forms.** The banner (360 x 64, radius 22) and the card
/// (460 x 300, radius 30; 420 x 236, radius 28 when compact) are drawn by one
/// view, and the banner's top edge *is* the card's top edge and its centre x the
/// card's centre x, so the cover, the title and the artist travel down and out
/// when the banner grows instead of being replaced. This file is the whole of
/// that arithmetic, kept pure so `Lock-Frames` is a test rather than a hope
/// (`LockCardLayoutTests`); `LockScreenCard` only lays views at these frames.
///
/// **The window is never resized.** `LockCardWindow` is cut once, to the card the
/// setting asks for — the largest thing it ever shows — and the banner is drawn
/// inside it, so its transparent remainder must take no clicks: hit-testing
/// follows the visible shape (`visibleRect`). Resizing a live window across the
/// moment the shield goes up is what stretched the window-server snapshot into a
/// half-scale card off to one side; read why in `LockCardWindow`.
///
/// Coordinates are points with the origin at the top-left of the thing they are
/// measured in — "canvas" for the window's card area, "shape" for the banner or
/// card itself — except `visibleRect`, which answers in AppKit's bottom-left
/// space because it is asked by an `NSView`.
enum LockCardLayout {
    enum Form: Hashable {
        case banner, card
    }

    // MARK: - The shape

    static let bannerSize = CGSize(width: 360, height: 64)
    /// A rounded rectangle, not a capsule (owner decision 4): with the cover
    /// inset 12 its 10-point corner is concentric with the banner's 22, where a
    /// capsule would have needed a round cover.
    static let bannerRadius: CGFloat = 22

    /// The card at each setting: 460 x 300, or 420 x **236** compact (it was 244
    /// before the redesign; the card without its lyric, spec §7.1).
    static func cardSize(_ size: NotchViewModel.LockCardSize) -> CGSize {
        switch size {
        case .standard: return CGSize(width: 460, height: 300)
        case .compact: return CGSize(width: 420, height: 236)
        }
    }

    /// Radius 30 holds a 10-point cover inset 20; 28 is the compact card's,
    /// concentric with the same cover.
    static func cardRadius(_ size: NotchViewModel.LockCardSize) -> CGFloat {
        size == .compact ? 28 : 30
    }

    static func shapeSize(_ form: Form, _ size: NotchViewModel.LockCardSize) -> CGSize {
        form == .banner ? bannerSize : cardSize(size)
    }

    static func shapeRadius(_ form: Form, _ size: NotchViewModel.LockCardSize) -> CGFloat {
        form == .banner ? bannerRadius : cardRadius(size)
    }

    /// The window's card area: the largest card, which is the card itself. What
    /// `LockScreenCard.size(for:)` returns and the window is cut to.
    static func canvas(_ size: NotchViewModel.LockCardSize) -> CGSize { cardSize(size) }

    /// The visible shape inside the canvas: **top-aligned and centred**, in
    /// either form. This is the whole "grows in place" rule — the banner and the
    /// card agree on `minY` and `midX`.
    static func shapeFrame(_ form: Form, _ size: NotchViewModel.LockCardSize) -> CGRect {
        let canvas = canvas(size)
        let shape = shapeSize(form, size)
        return CGRect(x: (canvas.width - shape.width) / 2, y: 0, width: shape.width, height: shape.height)
    }

    /// What takes clicks, given the canvas rect in the root view's AppKit space
    /// (origin bottom-left): the visible shape and nothing else. The window's
    /// remainder — a banner leaves most of the card area empty — belongs to
    /// whatever is under it, which while locked is the password field.
    static func visibleRect(_ form: Form, _ size: NotchViewModel.LockCardSize, canvas rect: CGRect) -> CGRect {
        let shape = shapeSize(form, size)
        return CGRect(x: rect.midX - shape.width / 2, y: rect.maxY - shape.height, width: shape.width, height: shape.height)
    }

    /// **Which shape takes clicks, given how long ago the banner began to grow**
    /// (review 2026-10-15). `LockCardPresentation.form` flips to `.card` the
    /// instant `expand()` runs, and the shape then spends `Theme.lockCardMorph`
    /// growing into it. Cutting the hit rect from `form` handed the whole 460 x 300
    /// to clicks for those 0.36 s while the glass was still the banner's size, so
    /// a quick second click below the banner landed on a control half-faded in
    /// outside the glass. The banner's rect stays the hit area until the shape has
    /// drawn the card, and then the card's takes over.
    ///
    /// Folding back needs no such wait: the card is leaving, and a click in the
    /// room it gives up is the lock screen's. `sinceExpand` is nil for a card that
    /// never was a banner (Rest as Banner off) and after a fold.
    static func hitForm(_ form: Form, sinceExpand: TimeInterval?, settle: TimeInterval) -> Form {
        guard form == .card, let sinceExpand else { return form }
        return sinceExpand >= settle ? .card : .banner
    }

    /// How long the grow takes to be drawn: the spring's response, or the 0.24 s
    /// crossfade under Reduce Motion (the same two the shape animates on,
    /// `Theme.lockCardMorph(reduceMotion:)`).
    static func morphSettle(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? Theme.reducedMotionDuration : Theme.lockCardMorphResponse
    }

    // MARK: - The song's header: cover, title, artist

    /// The three things that travel. Their frames in the shape: `Lock-Frames`.
    struct Header: Equatable {
        var cover: CGRect
        var coverRadius: CGFloat
        var title: CGPoint
        var titleSize: CGFloat
        var artist: CGPoint
        var artistSize: CGFloat
        /// The Output pane has no now-playing header (spec §7.3): the elements
        /// fade where they are rather than travel off.
        var visible = true
    }

    static func header(_ form: Form, pane: LockScreenCard.Pane, _ size: NotchViewModel.LockCardSize) -> Header {
        if form == .banner {
            return Header(
                cover: CGRect(x: 12, y: 12, width: 40, height: 40), coverRadius: 10,
                title: CGPoint(x: 64, y: 14), titleSize: Theme.TypeRole.subhead.size,
                artist: CGPoint(x: 64, y: 32), artistSize: Theme.TypeRole.body.size
            )
        }
        switch pane {
        case .player:
            return Header(
                cover: CGRect(x: 20, y: 20, width: 64, height: 64), coverRadius: 10,
                title: CGPoint(x: 98, y: 28), titleSize: Theme.TypeRole.title.size,
                artist: CGPoint(x: 98, y: 50), artistSize: Theme.TypeRole.subhead.size
            )
        case .lyrics:
            return Header(
                cover: CGRect(x: 20, y: 20, width: 34, height: 34), coverRadius: 8,
                title: CGPoint(x: 64, y: 21), titleSize: Theme.TypeRole.subhead.size,
                artist: CGPoint(x: 64, y: 38), artistSize: Theme.TypeRole.body.size
            )
        case .output:
            // Where the player's header was, so the fade is in place.
            var header = Header.player
            header.visible = false
            return header
        }
    }

    /// Title and artist stop short of the control at their right and truncate at
    /// the tail: the banner's ring (240 wide), the card's heart (276) or its
    /// chevron alone (300) — the compact card is 40 narrower — and the lyrics
    /// pane's Back chevron.
    static func titleWidth(
        _ form: Form, pane: LockScreenCard.Pane, _ size: NotchViewModel.LockCardSize, hasHeart: Bool
    ) -> CGFloat {
        if form == .banner { return 240 }
        let narrower: CGFloat = size == .compact ? 40 : 0
        switch pane {
        case .player, .output: return (hasHeart ? 276 : 300) - narrower
        case .lyrics: return chevron(pane: .lyrics, size).minX - 64 - 12
        }
    }

    // MARK: - Controls at the right

    /// The play/pause button's ring on the banner: 34 pt at (314, 15).
    static let ring = CGRect(x: 314, y: 15, width: 34, height: 34)
    static let ringLineWidth: CGFloat = 2

    /// The Collapse chevron on the player, and Back on the lyrics and output
    /// panes: 24 pt, at (420, 20) — (376, 20) on the compact card, 44 from its
    /// edge where the standard card's is 40 — and two points higher on the
    /// Output pane, where "Sound" is a line taller.
    static func chevron(pane: LockScreenCard.Pane, _ size: NotchViewModel.LockCardSize) -> CGRect {
        CGRect(
            x: size == .compact ? 376 : 420, y: pane == .output ? 18 : 20, width: 24, height: 24
        )
    }

    /// The heart, 28 pt, on the title row and 36 left of the chevron (384, 18).
    static func heart(_ size: NotchViewModel.LockCardSize) -> CGRect {
        CGRect(x: chevron(pane: .player, size).minX - 36, y: 18, width: 28, height: 28)
    }

    // MARK: - The player pane

    /// The sung line and, under it, its translation. Not on the compact card:
    /// it is the standard card without its lyric.
    static func lyric(_ size: NotchViewModel.LockCardSize) -> CGPoint? {
        size == .compact ? nil : CGPoint(x: 20, y: 104)
    }

    static func translation(_ size: NotchViewModel.LockCardSize) -> CGPoint? {
        size == .compact ? nil : CGPoint(x: 20, y: 125)
    }

    /// The seek row: elapsed, bar, remaining. 12 tall, 20 in from each edge.
    static func progress(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let card = cardSize(size)
        return CGRect(x: 20, y: size == .compact ? 110 : 158, width: card.width - 40, height: 12)
    }

    /// Previous, play/pause, next: 160 x 36, centred.
    static func transport(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let card = cardSize(size)
        return CGRect(x: (card.width - 160) / 2, y: size == .compact ? 132 : 190, width: 160, height: 36)
    }

    /// The foot rail: the Lyrics button at its left, the volume between, the
    /// Output button at its right. 28 tall, at y 252 (188 compact).
    static func footer(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let card = cardSize(size)
        return CGRect(x: 20, y: size == .compact ? 188 : 252, width: card.width - 40, height: 28)
    }

    static let footerButton: CGFloat = 28

    /// The volume slider, glyphs included: 40 in from the footer's left, 40 from
    /// its right (340 wide, 300 compact), centred on the rail.
    static func footerSlider(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let footer = footer(size)
        return CGRect(x: footer.minX + 40, y: footer.minY + 8, width: footer.width - 80, height: 12)
    }

    // MARK: - The Lyrics pane

    /// Where the lines go: from y 68 down to a little above the footer.
    static func lyricsArea(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let card = cardSize(size)
        let top: CGFloat = 68
        return CGRect(x: 20, y: top, width: card.width - 40, height: footer(size).minY - 8 - top)
    }

    /// Spacing of a row: one 16 pt line and the stack's 7, or — with a
    /// translation under it — the line, the translation and room to breathe
    /// (the board's 44, and 54 for the sung row, whose translation is larger).
    static let plainLyricPitch: CGFloat = 26
    static let translatedLyricPitch: CGFloat = 44
    static let translatedSungExtra: CGFloat = 10

    /// How many rows the pane holds. Plain, what it always held (five; three
    /// compact); with translations the board's four, and two on the compact
    /// card, whose area has room for the sung row and one more.
    static func lyricRowCount(_ size: NotchViewModel.LockCardSize, translated: Bool) -> Int {
        switch (size, translated) {
        case (.standard, false): return 5
        case (.standard, true): return 4
        case (.compact, false): return 3
        case (.compact, true): return 2
        }
    }

    /// How many rows sit above the sung one: the window is odd and centred when
    /// it can be, and puts the extra row below when it cannot — the board's four
    /// lines are one before the sung line and two after.
    static func rowsBefore(count: Int) -> Int { (count - 1) / 2 }

    /// The height `count` rows take, for the area check: the board's 176 for its
    /// four rows (44 + 54 + 44 + 34), which is exactly the area above the footer.
    static func lyricStackHeight(count: Int, translated: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        guard translated else { return CGFloat(count) * plainLyricPitch - (plainLyricPitch - 19) }
        // Every row but the last takes a full pitch; the last is its own 34
        // (a 20 pt line and a 14 pt translation); the sung row, whose
        // translation is the larger, takes the extra 10 on top.
        return CGFloat(count - 1) * translatedLyricPitch + 34 + translatedSungExtra
    }

    /// The small transport at the foot of the Lyrics pane: three 24-wide buttons
    /// that end 10 from the card's edge, and the seek row between the Hide
    /// Lyrics button and them (300 wide on the standard card, 260 compact).
    static func lyricsFooterProgress(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let footer = footer(size)
        let card = cardSize(size)
        return CGRect(x: 64, y: footer.minY + 8, width: card.width - 160, height: 12)
    }

    static func lyricsTransport(_ size: NotchViewModel.LockCardSize) -> CGRect {
        let footer = footer(size)
        let card = cardSize(size)
        return CGRect(x: card.width - 86, y: footer.minY, width: 76, height: footer.height)
    }

    // MARK: - The Output pane (the macOS Sound module)

    static let outputCircle: CGFloat = 26
    /// Devices stand 36 pt apart.
    static let outputRowPitch: CGFloat = 36
    /// The list's top: the first circle is at y 98 and its row starts 5 above.
    static let outputListTop: CGFloat = 93
    static let outputListBottomMargin: CGFloat = 8

    static let outputTitle = CGPoint(x: 20, y: 20)
    /// "Output", the heading over the list.
    static let outputHeading = CGPoint(x: 20, y: 80)

    /// The volume row: 8-pt track and a knob, 380 wide on the standard card
    /// between a quiet and a loud speaker at 26 and 434 — a 420 frame, glyph 12,
    /// gap 8, bar, gap 8, glyph 12.
    static func outputVolume(_ size: NotchViewModel.LockCardSize) -> CGRect {
        CGRect(x: 20, y: 52, width: cardSize(size).width - 40, height: 16)
    }

    static let outputBarWidthOnStandard: CGFloat = 380

    /// Whole rows between the list's top and the card's foot margin: five on the
    /// standard card (the board's five devices), three on the compact one.
    static func outputRowsThatFit(_ size: NotchViewModel.LockCardSize) -> Int {
        let room = cardSize(size).height - outputListTop - outputListBottomMargin
        return max(1, Int(room / outputRowPitch))
    }

    /// The height of the scrolling list for `count` devices: exactly its rows up
    /// to what fits, and past that the last visible row is cut in half — the
    /// list scrolls without indicators over the shield, and a row sliced by the
    /// edge is what says there is more below.
    static func outputListHeight(count: Int, _ size: NotchViewModel.LockCardSize) -> CGFloat {
        guard count > 0 else { return 0 }
        let fit = outputRowsThatFit(size)
        if count <= fit { return CGFloat(count) * outputRowPitch }
        return CGFloat(fit - 1) * outputRowPitch + outputRowPitch / 2
    }
}

private extension LockCardLayout.Header {
    /// The player pane's header, which the Output pane keeps in place, hidden.
    static var player: LockCardLayout.Header {
        LockCardLayout.header(.card, pane: .player, .standard)
    }
}

/// The state of the lock banner and card: which form is showing and which pane
/// the card is on — and the lock card's registration with the lyric
/// translation.
///
/// An object of its own, owned by `LockCardWindow` and handed to the view,
/// because two things outside SwiftUI need to read it: the window's hit-test
/// (which rect takes clicks depends on the form) and the translation service
/// (the card wants translations only while it is the card).
///
/// **The translation demand follows the card, not the banner.** A batch costs
/// work and, with Translate Online on, requests against a daily allowance
/// (review 2026-10-15): the banner draws no lyric, so it asks for none. The demand
/// is raised when the card is the form on screen — at present when Rest as
/// Banner is off, on the click that grows the banner otherwise — and lowered when
/// it folds back or the lock ends, **with the epoch it was raised under**, so a
/// late lowering after the panel was rebuilt cannot cancel the new panel's own
/// registration (`LyricTranslation.setDemand`). The window ends it explicitly at
/// dismiss rather than trusting `onDisappear`, which AppKit hosting does not
/// promise when a content view is discarded.
@MainActor
final class LockCardPresentation: ObservableObject {
    @Published private(set) var form: LockCardLayout.Form
    @Published var pane: LockScreenCard.Pane {
        didSet { if pane != oldValue { syncDemand() } }
    }
    /// Whether the card rests as a banner and has a chevron to fold back to.
    let restsAsBanner: Bool

    /// The Card Size the lock window was cut for. Only the standard card draws a
    /// lyric on its player pane, so the compact one asks for a translation only on
    /// the Lyrics pane (review 2026-10-15: it used to ask for every locked song).
    var size: NotchViewModel.LockCardSize {
        didSet { if size != oldValue { syncDemand() } }
    }

    /// Whether there is a song. The window feeds it from the media controller; a
    /// card with no track draws nothing, so it has nothing to translate.
    var hasTrack: Bool {
        didSet { if hasTrack != oldValue { syncDemand() } }
    }

    private var translation: LyricTranslation?
    private var raisedEpoch: Int?
    private var ended = false
    /// When the banner began to grow into the card, on the system uptime clock.
    private var expandedAt: TimeInterval?

    init(
        restsAsBanner: Bool, pane: LockScreenCard.Pane = .player,
        size: NotchViewModel.LockCardSize = .standard, hasTrack: Bool = true
    ) {
        self.restsAsBanner = restsAsBanner
        self.form = restsAsBanner ? .banner : .card
        self.pane = pane
        self.size = size
        self.hasTrack = hasTrack
    }

    /// The banner grows into the card. A click on the banner anywhere but its
    /// ring.
    func expand(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard form == .banner else { return }
        form = .card
        expandedAt = now
        syncDemand()
    }

    /// The card folds back into the banner, on its first pane. Only a card that
    /// rests as a banner has one to fold into.
    func collapse() {
        guard restsAsBanner, form == .card else { return }
        pane = .player
        form = .banner
        expandedAt = nil
        syncDemand()
    }

    /// The shape that takes clicks right now: the banner's until the grow has
    /// been drawn (`LockCardLayout.hitForm`), then `form`.
    func hitForm(
        reduceMotion: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> LockCardLayout.Form {
        LockCardLayout.hitForm(
            form, sinceExpand: expandedAt.map { now - $0 },
            settle: LockCardLayout.morphSettle(reduceMotion: reduceMotion)
        )
    }

    /// Whether the player pane draws the Collapse chevron: only when there is a
    /// banner to fold back to (Rest as Banner off has no chevron, spec §7.1).
    var showsCollapse: Bool { restsAsBanner }

    /// Whether this form draws a translated line: the card, with a song, and a
    /// pane that carries a lyric — the standard card's player or the Lyrics pane.
    /// Only the compact card's player pane has none. The Output pane is not asked
    /// to let go on either size, so a visit there does not cancel a batch in
    /// flight (re-review 2026-10-15: on the compact card it did, against this
    /// very comment, and Lyrics -> Output -> Lyrics threw the batch away).
    var wantsTranslation: Bool {
        !ended && form == .card && hasTrack && (size == .standard || pane != .player)
    }

    // MARK: - Translation demand

    /// The service the card raises its demand on. Raises at once when the card
    /// is already the form on screen.
    func attach(translation: LyricTranslation) {
        self.translation = translation
        syncDemand()
    }

    /// The lock ended: lower the demand, now, and never raise it again.
    func end() {
        ended = true
        syncDemand()
    }

    /// Asks the service for what this card wants, again. A second `present` (a
    /// display change while locked) lands here: the controller's `rebuild()` had
    /// called `resetDemand()`, which dropped the registration without telling the
    /// card, so the card must look at the epoch again (review 2026-10-15).
    func resync() { syncDemand() }

    /// **Raised under an epoch, and raised again under a newer one.** `raisedEpoch`
    /// used to be only "have I raised?": after `resetDemand()` it still held the
    /// old epoch, the card believed it was registered, and with Rest as Banner off
    /// nothing re-raised it until unlock. Now a registration under an epoch that is
    /// no longer the service's counts as none, so the card raises under the current
    /// one; and a lowering is made under the epoch that was raised, which the
    /// service ignores once it has moved on (`LyricTranslation.setDemand`).
    private func syncDemand() {
        guard let translation else { return }
        if wantsTranslation {
            guard raisedEpoch != translation.demandEpoch else { return }
            raisedEpoch = translation.demandEpoch
            translation.setDemand(.lockCard, true)
        } else if let epoch = raisedEpoch {
            raisedEpoch = nil
            translation.setDemand(.lockCard, false, epoch: epoch)
        }
    }
}

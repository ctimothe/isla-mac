import SwiftUI

/// Sizes, radii and colours of each surface: player, stage, Shelf, Clipboard, Translate, Settings.
extension Theme {
    // MARK: - Lyric column and tall page (spec §5.4)

    /// The Sync pill's solid fill: `#3A3A3C` at 0.96. A solid, not glass — it
    /// sits in an opaque panel with nothing behind it to sample — and a Theme
    /// value rather than a colour written at the view, as the rule asks.
    static let syncPillFill = Color(red: 58.0 / 255, green: 58.0 / 255, blue: 60.0 / 255).opacity(0.96)
    static let syncPillSize = CGSize(width: 74, height: 24)

    /// The version-mismatch notice: 488 x 40, radius 9, white 0.07 with a
    /// hairline (`Lyrics-Version-Mismatch`). Its width is the pane's at the
    /// default body; it follows the pane at other widths.
    static let mismatchNoticeHeight: CGFloat = 40
    static let mismatchNoticeRadius: CGFloat = 9
    static let mismatchNoticeFill = Color.white.opacity(0.07)

    /// The Edit Lyrics sheet (spec §5.5, `Lyrics-Editor`): `#2A2A2C`, with fields
    /// at white 0.06 inside a white 0.16 hairline.
    static let sheetFill = Color(red: 42.0 / 255, green: 42.0 / 255, blue: 44.0 / 255)
    static let editorFieldFill = Color.white.opacity(0.06)
    static let editorFieldEdge = Color.white.opacity(0.16)

    // MARK: - Artwork

    /// The two ends of the cover's travel between the pill and the open panel.
    ///
    /// One function because there is one cover. The pill hardcoded 22 pt at
    /// radius 6 in `NotchContentView` and the pane hardcoded 118 pt at radius 14
    /// in `MediaPane` — two descriptions of one object, in two files, which is
    /// the same mistake as drawing it twice and crossfading between the copies.
    /// A `matchedGeometryEffect` interpolates the frame; what it cannot do is
    /// notice that the two ends disagree about what shape they are.
    ///
    /// The corner is absolute at each end, not a proportion of the side.
    ///
    /// It was briefly proportional, at the `side / 5.5` `LockScreenCard` draws
    /// its own cover at, on the reasoning that one object should keep its shape
    /// while it travels. That is the wrong reasoning and it shows: a thumbnail
    /// wants to read as a rounded chip and a large cover wants to read as a
    /// picture, which is why Apple's small artwork is proportionally rounder
    /// than its large artwork rather than the same. Holding the ratio put the
    /// 118 pt cover at 21.5 pt — 18 per cent — a chip the size of a postcard.
    /// `side / 5.5` is right for the 42–62 pt thumbnail it was set on and wrong
    /// at this size, so each end keeps the value it actually wants and the
    /// morph interpolates the frame between them.
    ///
    /// The compact end is 22 pt at radius 5 since spec §19.4 (2026-10-17; it
    /// was 24 at 6 from 2026-10-15, and 22 at 6 before that): the reference's
    /// cover, at (17.3, 8) on a 38 pt island. On the 24 pt island Isla draws
    /// for a display without a notch it is 16 (`CompactIslandLayout`).
    ///
    /// The open end is the player's cover, 60 pt at radius 10 since R8 (spec
    /// §19.6; it was 132 at 14 from 2026-10-15, and 118 before that): the
    /// player is one row now, the cover at its left. Read from `PlayerLayout`
    /// so the morph cannot end on a cover the player no longer draws — R8 left
    /// this at 132 for a day, and the lab's keyframes grew the cover past the
    /// row it lands in.
    static func artworkMetrics(isOpen: Bool) -> (side: CGFloat, cornerRadius: CGFloat) {
        isOpen ? (PlayerLayout.coverSide, PlayerLayout.coverRadius) : (22, 5)
    }

    // MARK: - The compact island's surface (spec §2.1, §3.2, §3.3)

    /// A paused cover darkens to 0.55 of itself rather than turning 0.58
    /// see-through (spec §3.2). The old opacity let a bright wallpaper
    /// through the cover — on a pale desktop a paused cover read as a ghost —
    /// where multiplying the picture by 0.55 darkens it on any background.
    static let pausedCoverBrightness: Double = 0.55

    /// The well behind a missing cover on the compact island (spec §3.2): white
    /// at 0.14 under a `music.note`, drawn in place of the picture so the left
    /// wing never reads as a hole.
    static let coverWell = Color.white.opacity(0.14)

    // MARK: - The player (spec §4)

    /// The owner's red, `#FF453A` (spec §2.1): the LIVE mark and the circle under
    /// the output that is playing. Fixed rather than the system accent — it is
    /// a mark of Isla's own — and white on it holds the 3:1 non-text floor
    /// (3.4:1), which is all a glyph in a circle is asked for.
    static let accent = Color(red: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255)
    static let accentNSColor = NSColor(srgbRed: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255, alpha: 1)

    /// A paused cover in the player dims to 0.8 of itself (spec §4.2) — the
    /// island's 0.55 is for a 24 pt thumbnail that has to read as asleep; a 132
    /// pt picture only needs to say so. Applied with `colorMultiply`, never
    /// SwiftUI's `.brightness`, which is additive and would lift the black.
    static let playerPausedCoverBrightness: Double = 0.8

    /// The sung line while paused (spec §4.2): 0.7 of itself.
    static let playerPausedLyricOpacity: Double = 0.7

    /// White 0.30 (0.50 with Increase Contrast): placeholders and glyphs nobody
    /// has to read (spec §2.1 `quaternary`) — the note in a missing cover's well.
    static func quaternaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.50 : 0.30
    }

    @MainActor static var quaternary: Color {
        Color.white.opacity(quaternaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// The well that stands in for a missing cover (spec §4.7): white 0.08, the
    /// board's `fill` token.
    static let coverMissingWell = Color.white.opacity(0.08)

    /// The note in a missing cover's well: 35 points (spec §4.7). A glyph
    /// fitted to a 132 pt well, not type, so a size of its own and not a role.
    static let playerCoverNoteSize: CGFloat = 35
    // MARK: - The player, activities first (spec §19.6)

    /// The title, white 0.80 at 16 medium; the artist under it, white 0.50 at
    /// 14 regular — and the same 0.50 for the artist after "–" while the sung
    /// line has the subtitle.
    static let playerTitleOpacity: Double = 0.80
    static let playerArtistOpacity: Double = 0.50
    /// The sung line's sweep: the part sung at 0.82, the rest at 0.45.
    static let playerSungOpacity: Double = 0.82
    static let playerUnsungOpacity: Double = 0.45
    /// The times either side of the bar: SF Pro Rounded 11 medium at 0.40.
    static let playerTimeOpacity: Double = 0.40
    /// The progress bar's track and fill.
    static let playerTrackOpacity: Double = 0.15
    static let playerFillOpacity: Double = 0.50
    /// Previous, Play / Pause and Next at 0.90; Favourite and Output, the
    /// controls either side that are not the transport, at 0.50.
    static let playerTransportOpacity: Double = 0.90
    static let playerSecondaryControlOpacity: Double = 0.50

    // MARK: - The lyrics stage's foot (spec §19.6)

    /// The hairline over the foot, white 0.12.
    static let stageHairline = Color.white.opacity(0.12)
    /// The artist under the title, white 0.55.
    static let stageArtistOpacity: Double = 0.55
    /// The progress's track, white 0.18; its fill is the cover's tint.
    static let stageTrack = Color.white.opacity(0.18)

    /// The mark on a hairline round the player's cover (spec §4.1): white 0.14.
    static let coverEdge = Color.white.opacity(0.14)

    /// The island's colour under the pointer: a solid `#1C1C1E` in place of the
    /// white gradient lift it wore until 2026-10-15. Nothing moves on a playing
    /// island — the surface alone answers the pointer — and the resting notch's
    /// nudge (`hoverNudge`) grows into the same fill.
    static let islandHover = Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)

    /// The lock card's Solid panel (spec §7.2): `#1C1C1E`, the same grey the
    /// island takes under the pointer. Also what stands in for the cover's light
    /// when a song has no cover (`LockCardMaterial.Layer.neutralFill`) — Automatic
    /// and Tinted keep their opacity floor with or without a picture.
    static let lockCardSolid = islandHover

    /// The same black at the alpha the decision gave it: 0.30 over a dark
    /// wallpaper, more where the type needs it (`LockCardLegibility.transparentWash`).
    static func lockCardTransparent(alpha: Double) -> Color { Color.black.opacity(alpha) }

    /// The system green, `#30D158`: the charging bolt and its level.
    static let chargingGreen = Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

    /// The system red on a dark surface, `#FF453A`: a battery at 20 percent or
    /// less on either Charging activity, as the battery menu fills one.
    static let lowBatteryRed = Color(red: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255)

    /// The two charge colours under Increase Contrast: the system's own
    /// accessible dark variants, `#30DB5B` and `#FF6961`.
    static let chargingGreenContrast = Color(red: 48.0 / 255, green: 219.0 / 255, blue: 91.0 / 255)
    static let lowBatteryRedContrast = Color(red: 255.0 / 255, green: 105.0 / 255, blue: 97.0 / 255)

    /// The island's stroke (spec §19.2), which replaced §3.3's key line: 2 pt
    /// centred on the outline, the activity's tint at 0.21 or white at 0.14,
    /// raised to 0.42 and 0.30 under Increase Contrast. Measured from the
    /// reference screenshots; to be confirmed on Aerial, Sonoma and a white
    /// wallpaper, owed check R7-H3.
    static let islandStrokeWidth: CGFloat = 2
    static let islandStrokeTintOpacity: Double = 0.21
    static let islandStrokeWhiteOpacity: Double = 0.14
    static let islandStrokeTintContrastOpacity: Double = 0.42
    static let islandStrokeWhiteContrastOpacity: Double = 0.30

    /// The shadow a tall shape casts (spec §19.2): black 0.22, radius 14, no
    /// offset, on a shape taller than 68 — a surface or an alert, never a
    /// compact activity or the peek.
    static let islandShadowThreshold: CGFloat = 68
    static let islandShadowOpacity: Double = 0.22
    static let islandShadowRadius: CGFloat = 14

    // MARK: - The Shelf (spec §8)

    /// The blue of the Shelf (spec §19.7): the bubble's count, the drop target
    /// under the pointer and a picked tile's ring. The system's own blue, the
    /// same value as `SettingsTint.blue`.
    static var shelfBlue: Color { SettingsTint.blue.color }

    // MARK: - The update alert (spec §19.5 f)

    /// The glyph's gradient and Install's capsule (at 0.22): the system's
    /// blue, as the Shelf's is.
    static var updateBlue: Color { SettingsTint.blue.color }
    /// The Settings update card's progress bar: the person's accent, as every
    /// native progress indicator is (native pass 2026-10-25; it was the fixed
    /// system blue whatever accent the Mac was set to).
    static var updateAccent: Color { Color(nsColor: .controlAccentColor) }
    /// Install's title, `#3E8EF7`: a lighter blue than the capsule's, so the
    /// default button's word still reads on blue 0.22 over black.
    static let updateInstallTitle = Color(red: 62.0 / 255, green: 142.0 / 255, blue: 247.0 / 255)
    /// Later's capsule (at 0.22): the system's grey.
    static var updateLaterFill: Color { SettingsTint.grey.color }

    /// A tile is Finder's icon view (§19.7, amended 2026-10-26, second
    /// amendment): no plate behind a tile, resting or under the pointer — a
    /// plate was the Photos grid's way of saying "card", and the Shelf holds
    /// files. A picked tile gets the icon's backdrop only (Finder's
    /// unemphasized icon highlight, white 0.15 on the dark panel, radius 5)
    /// and its name on the selected-text pill.
    static let shelfSelectedWell = Color.white.opacity(0.15)
    static let shelfIconBackdropRadius: CGFloat = 5
    /// The selected name's pill: `selectedContentBackgroundColor`, which is
    /// the person's Highlight colour in System Settings › Appearance (the
    /// accent unless it was set apart) and what Finder fills a selected
    /// name with. Dynamic, so a change reaches the next frame. Finder greys
    /// it in a window that is not key; this panel never becomes key (Shell,
    /// CLAUDE.md) while it is plainly the thing in use, so it keeps the active
    /// look, as the switches do (`switchOnFill`).
    static let shelfCaptionHighlight = Color(nsColor: .selectedContentBackgroundColor)
    static let shelfCaptionHighlightRadius: CGFloat = 4
    /// Room either side of a highlighted line, so the fill does not end on the
    /// glyphs' edges.
    static let shelfCaptionHighlightInset: CGFloat = 3
    /// A tile's name: `labelColor`, white under Increase Contrast — the
    /// panel is fixed `.darkAqua`, which does not pass that setting on to the
    /// system colours (`settingsLabel`'s reason).
    @MainActor static var shelfTileName: Color { settingsLabel }
    /// The line under the name, Finder's "item info": `secondaryLabelColor`,
    /// the grey Finder sets it in, and not the accent (the owner asked why a
    /// tile's date wore the system colour; it is the pill that does, the date
    /// never). White 0.75 under Increase Contrast, as `settingsSecondaryLabel`.
    @MainActor static var shelfTileInfo: Color { settingsSecondaryLabel }

    /// The remove badge (§19.7): `xmark.circle.fill` at white 0.62 over a 14 pt
    /// disc of black 0.28, so the cross reads on a bright thumbnail.
    static let shelfBadgeGlyph = Color.white.opacity(0.62)
    static let shelfBadgeDisc = Color.black.opacity(0.28)

    /// A drop target under the pointer (spec §19.7): blue 0.18 inside a 2 pt
    /// blue ring, its second line white 0.75; the other white 0.07, its second
    /// line white 0.55.
    static var shelfDropWellLit: Color { shelfBlue.opacity(0.18) }
    static let shelfDropRingWidth: CGFloat = 2
    static let shelfDropWellResting = Color.white.opacity(0.07)
    static let shelfDropCaptionLit: Double = 0.75
    static let shelfDropCaptionResting: Double = 0.55
    /// The empty tray's line, white 0.55.
    static let shelfEmptyLineOpacity: Double = 0.55

    // MARK: - Pages (spec §19.16)

    /// The row of dots under a page: the current page's dot white 0.90, the
    /// others white 0.30, and 0.45 while the pointer is over the row.
    static let pageDotCurrent: Double = 0.90
    static let pageDotOther: Double = 0.30
    static let pageDotOtherHovered: Double = 0.45

    /// How far a list fades into an edge that cuts it (`scrollEdgeFade`,
    /// H-017). Ten points: enough to read as "continues" at a 26 pt row, and
    /// short enough that a covered clipboard row under the drifting dots
    /// still reads as covered rather than as a third state.
    static let scrollFadeLength: CGFloat = 10

    // MARK: - The Clipboard (spec §9)

    /// The well behind a hovered row and a row that has just been copied, white
    /// at 0.08 (spec §9.2) — Increase Contrast steps it to 0.18, the same rule
    /// every translucent fill follows (§2.1), so a hovered row can still be told
    /// from the rest.
    static func clipboardWellOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.18 : 0.08
    }

    @MainActor static var clipboardWell: Color {
        Color.white.opacity(clipboardWellOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    // MARK: - Translate (redesign 2026-10-15, spec §11)

    /// The source card's fill: white at 0.07 on the black island (spec §11), the
    /// well a person can tell is typed into. Increase Contrast steps it to 0.16 —
    /// the same rule every translucent fill follows (§2.1) — so the card still
    /// reads as a shape; the placeholder and the counter on it are drawn through
    /// `tertiary` and `quaternary`, which carry their own contrast floors.
    static func translateCardOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.16 : 0.07
    }

    /// The card's half-point hairline, white at 0.08 (spec §11); 0.35 as a
    /// defined edge under Increase Contrast, between the base hairline and the
    /// selected chip's 0.55 so a card is edged without shouting.
    static func translateCardEdgeOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.35 : 0.08
    }

    /// The language pop-ups' plate: white at 0.12 (the board's `popup()`), 0.24
    /// under Increase Contrast — the `surface` ratio, doubled and rounded.
    static func popUpOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.24 : 0.12
    }

    @MainActor static var translateCardFill: Color {
        Color.white.opacity(translateCardOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    @MainActor static var translateCardEdge: Color {
        Color.white.opacity(translateCardEdgeOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    @MainActor static var popUpFill: Color {
        Color.white.opacity(popUpOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// A search match: `#FFD60A` behind `#1D1D1F` text (spec §2.1, §9.3) — the
    /// find-in-page yellow Safari, Notes and Mail mark a match with, so nobody
    /// has to be told what it means. Dark text on it, whatever the row's own
    /// colour: white on this yellow would be 1.4:1.
    static let findHighlight = Color(red: 255.0 / 255, green: 214.0 / 255, blue: 10.0 / 255)
    static let findHighlightText = Color(red: 29.0 / 255, green: 29.0 / 255, blue: 31.0 / 255)

    /// The warning orange `#FF9F0A` (spec §2.1): an alert that is a warning and
    /// not a failure. The denied-access alert's glyph, ring and fill are this
    /// at full, 0.35 and 0.12.
    static let warning = Color(red: 255.0 / 255, green: 159.0 / 255, blue: 10.0 / 255)

    // MARK: - Settings: the sidebar and the grouped form (spec §10)

    /// The colour of a drawn section tile in the sidebar: the system's own
    /// colours by name, never hex (native pass 2026-10-25; they were the dark
    /// variants' hex values, which froze them against a macOS that retunes
    /// its palette and against Increase Contrast). The grey System Settings
    /// gives General and Keyboard, the blue of Privacy & Security, the pink
    /// of Music, the orange of the lyric bubble and the indigo of the lock
    /// screen — `ISEnclosureColor`'s names.
    enum SettingsTint: CaseIterable {
        case grey, blue, rose, orange, indigo

        var nsColor: NSColor {
            switch self {
            case .grey: return .systemGray
            case .blue: return .systemBlue
            case .rose: return .systemPink
            case .orange: return .systemOrange
            case .indigo: return .systemIndigo
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    /// A form group's fill (native pass, 2026-10-25). System Settings' box is
    /// +9/255 over its window; the system's own box vanishes on black (6/255,
    /// probe), so Isla draws one at white 0.065 (≈ 17/255) — the native step,
    /// re-derived for the black panel — with no outer edge, as native boxes
    /// have none. Increase Contrast raises it to 0.14 so the group is still a
    /// shape (§2.1: every translucent fill steps up).
    static func settingsGroupOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.14 : 0.065
    }

    /// A row label's and a header's white: `labelColor` under the dark
    /// appearance is white at 0.85 (measured 224/255 on black), and so is
    /// this. Full white with Increase Contrast, which the panel's fixed
    /// `.darkAqua` appearance does not otherwise pass to the system colours.
    static func settingsHeaderOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 1.0 : 0.85
    }

    @MainActor static var settingsGroupFill: Color {
        Color.white.opacity(settingsGroupOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    /// The selected sidebar row: the system accent, as System Settings draws
    /// its selection while you use it (driver decision for the owner,
    /// 2026-10-25: the active look, because the panel is plainly the thing
    /// in use though it is never key — the same reasoning as the switches).
    static let settingsSidebarSelection = Color(nsColor: .selectedContentBackgroundColor)
    /// Labels and headers: `labelColor`, white under Increase Contrast.
    @MainActor static var settingsLabel: Color {
        SystemAppearance.shared.increaseContrast ? Color.white : Color(nsColor: .labelColor)
    }
    @MainActor static var settingsHeader: Color { settingsLabel }
    /// Footers and a row's second line: `secondaryLabelColor` (white 0.55
    /// under the dark appearance), white 0.75 under Increase Contrast.
    @MainActor static var settingsSecondaryLabel: Color {
        SystemAppearance.shared.increaseContrast
            ? Color.white.opacity(secondaryOpacity(increaseContrast: true))
            : Color(nsColor: .secondaryLabelColor)
    }
    /// The hairline between rows: `separatorColor`, which lands +13/255 over
    /// the group as the native separator does over its box (probe), and the
    /// panel's stronger hairline under Increase Contrast.
    @MainActor static var settingsSeparator: Color {
        SystemAppearance.shared.increaseContrast ? hairline : Color(nsColor: .separatorColor)
    }

    /// The glyph on a drawn sidebar tile. The tile's 0.5 pt lit top edge went
    /// in the native pass: IconServices' own tiles carry a gradient, and the
    /// drawn ones copy that instead (`SettingsSectionIcon`).
    static let settingsIconGlyph = Color.white
    /// System Settings' pane icons sit their tile in 832 of a 1024 canvas on
    /// macOS 27 (104/128 at 128 pt, 26/32 at 32 pt, probe), so an icon drawn
    /// at `side × 1024 / 832` shows a `side` tile.
    static let systemPaneIconOpticalScale: CGFloat = 1024.0 / 832.0
    /// The Lock Screen section's style previews: the ring round the chosen one
    /// (spec §10, accent 2 pt) and the hairline round the others.
    static let settingsPreviewRingWidth: CGFloat = 2
    static let settingsPreviewEdge = Color.white.opacity(0.2)

    /// The field that is recording a shortcut: the system accent at 0.18 under
    /// a 1.5 pt accent ring (spec §2.1, "the recording field"). It was Isla's
    /// own red until the native pass (2026-10-25): in Settings, "active" is
    /// the person's accent, as everywhere else on their Mac.
    static let recordingFill = Color(nsColor: .controlAccentColor).opacity(0.18)
    static let recordingRing = Color(nsColor: .controlAccentColor)
    static let recordingRingWidth: CGFloat = 1.5

    /// How much larger than its frame an app's icon is drawn so its squircle
    /// fills the frame. macOS app icons sit an 824 pt squircle in a 1024 pt
    /// canvas (the Big Sur grid) and leave the margin transparent; drawn to
    /// fit, a real icon read as a smaller tile than the SF-symbol ones beside
    /// it. `AppIconImage` is the one place it is applied.
    static let appIconOpticalScale: CGFloat = 1024.0 / 824.0

    /// The fallback Spotify mark's green and the near-black of its arcs, shown
    /// only when the real Spotify is not installed — everyone who has it sees
    /// its own icon (`AppIcons`). Drawn rather than shipped: no brand asset
    /// travels in the bundle. Not `settingsConnected`: that green says "on and
    /// working", this one is a brand's.
    static let spotifyMark = Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255)
    static let spotifyMarkInk = Color(red: 25.0 / 255, green: 20.0 / 255, blue: 20.0 / 255)

    // MARK: Lock Screen style previews (spec §10)
    //
    // Each preview is the R2 card's material over a stand-in wallpaper, drawn
    // by `LockCardMaterial.decision` and never a screenshot of it. The wallpaper
    // is Sonoma's three bands, the board's own sample; the cover's light is the
    // warm brown the board's sample cover lights its card with.

    static let settingsPreviewWallpaper: [Color] = [
        Color(red: 242.0 / 255, green: 116.0 / 255, blue: 90.0 / 255),
        Color(red: 63.0 / 255, green: 143.0 / 255, blue: 91.0 / 255),
        Color(red: 111.0 / 255, green: 123.0 / 255, blue: 232.0 / 255),
    ]
    static let settingsPreviewCoverLight = Color(red: 122.0 / 255, green: 62.0 / 255, blue: 51.0 / 255)
    /// The marks on the miniature card: the title and scrubber's fill, and the
    /// quieter artist line, track and transport.
    static let settingsPreviewInk = Color.white.opacity(0.9)
    static let settingsPreviewInkSoft = Color.white.opacity(0.45)
    static let settingsPreviewCover = Color.white.opacity(0.30)
}

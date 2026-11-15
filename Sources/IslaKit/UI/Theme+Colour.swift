import SwiftUI

/// The contrast ramp, the lock card's ramp and the Settings switch.
extension Theme {
    // MARK: - Contrast ramp
    //
    // Every token below is a function of Increase Contrast, not a flat value.
    // The setting used to reach two `strokeBorder` calls in `GlassSurface` and
    // nothing else, while the type ramp sat untouched and the lyric context
    // lines at white 0.18 computed to 1.54:1. The opacity functions are pure so
    // tests can compute WCAG ratios against black (`ContrastRampTests`); the
    // `Color` accessors below read `SystemAppearance.shared.increaseContrast`,
    // and the one observation that makes a live change redraw lives on
    // `NotchContentView` — every pane is its descendant, so one `@ObservedObject`
    // at the root invalidates the whole tree.
    //
    // The existing names keep working so call sites do not all change at once;
    // new code that cares about the setting can call the functions directly.

    /// White 0.55 over black is 6.27:1; 0.75 is 11.45:1.
    static func secondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.75 : 0.55
    }

    /// Carries nearly every 9–10pt label in the panel — tab titles, counters,
    /// scrubber times, section headers, placeholders. At 0.32 white over black
    /// that computes to 2.67:1, far under the 4.5:1 WCAG AA asks of text this
    /// size, and 9pt is precisely the type least able to afford it. 0.46 gave
    /// 4.58:1 over black and cleared it there, but a label seldom sits on bare
    /// black: on `surface` (Settings notes, section rows) it was 4.29:1
    /// (F-052). 0.50 is 5.28:1 over black and 4.8:1 on `surface`, without
    /// turning every label into a headline; 0.65 gives 8.60:1 once Increase
    /// Contrast is on. The fills that are brighter still — a hovered Shelf
    /// card, the stacked capsules of a choice row — raise the label per
    /// fill with `tertiaryOpacity(over:increaseContrast:)`.
    static func tertiaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.65 : 0.50
    }

    /// The panel's translucent white fills a label can sit on, by name, so a
    /// label's backdrop is stated once and measured by `ContrastRampTests`.
    enum Fill {
        case surface, surfaceHover, selectedChip
        /// The form's group (spec §10): a value or a row's second line sits on
        /// it. The sidebar's selected row is the system accent since the
        /// native pass (2026-10-25), and its white label is the system's
        /// own pairing, so it is not a fill of this ramp.
        case settingsGroup

        func opacity(increaseContrast: Bool) -> Double {
            switch self {
            case .settingsGroup: return Theme.settingsGroupOpacity(increaseContrast: increaseContrast)
            case .surface: return Theme.surfaceOpacity(increaseContrast: increaseContrast)
            case .surfaceHover: return Theme.surfaceHoverOpacity(increaseContrast: increaseContrast)
            case .selectedChip: return Theme.selectedChipOpacity(increaseContrast: increaseContrast)
            }
        }
    }

    /// What an unselected option of a Settings choice row sits on: the section
    /// card's `surface` and the capsule group's own `surface` on top of it. At
    /// Increase Contrast those two stack to 0.48 of white, where even pure white
    /// text reaches only 4.24:1, so the capsule group gives up its fill for the
    /// defined edge that setting asks for and the option sits on the card alone.
    static func choiceOptionFills(increaseContrast: Bool) -> [Fill] {
        increaseContrast ? [.surface] : [.surface, .surface]
    }

    /// The grey (sRGB, 0…1) that white layers of these opacities make over the
    /// panel's black, source-over, first layer first.
    static func composite(_ opacities: [Double]) -> Double {
        opacities.reduce(0) { grey, alpha in alpha + (1 - alpha) * grey }
    }

    /// WCAG contrast of white at `textOpacity` over an sRGB grey.
    static func contrast(textOpacity: Double, overGrey grey: Double) -> Double {
        LockCardLegibility.contrast(textOpacity: textOpacity, overGrey: grey)
    }

    /// The smallest white opacity, no dimmer than the tertiary ramp, that
    /// clears 4.5:1 over these stacked fills. Searched in whole percent so the
    /// answer is a value a designer would write; the tertiary ramp itself is
    /// returned where it already clears.
    static func tertiaryOpacity(over fills: [Fill], increaseContrast: Bool) -> Double {
        let base = tertiaryOpacity(increaseContrast: increaseContrast)
        let grey = composite(fills.map { $0.opacity(increaseContrast: increaseContrast) })
        var candidate = base
        while candidate < 1, contrast(textOpacity: candidate, overGrey: grey) < 4.5 {
            candidate = (candidate * 100).rounded() / 100 + 0.01
        }
        return min(candidate, 1)
    }

    /// A filled shape has to read as a filled shape. 0.08 was 1.14:1 over
    /// black — the selected tab chip and the empty scrubber track were not
    /// visible as shapes at all. 0.16 is 1.44:1, the smallest round value that
    /// clears the 1.4 floor `ContrastRampTests` holds; this is a shape fix for
    /// everyone, not an accessibility variant, so the base moves and not only
    /// the contrast one.
    static func surfaceOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.28 : 0.16
    }

    /// 0.14 was 1.35:1. 0.26 is 2.10:1, the smallest round value clearing the
    /// 2.0 floor — same reasoning as `surfaceOpacity`: the hover state has to
    /// differ from the surface by something a person can see.
    static func surfaceHoverOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.38 : 0.26
    }

    /// A 1pt edge, not a fill, so the base stays hairline-thin at 0.10
    /// (1.20:1) and only the contrast variant becomes a defined border at
    /// 0.55 — the same white-0.55 `ShelfPane`'s selected tile already uses.
    /// Hairline-only edges stay thin by design; raising them is follow-up, not this change.
    static func hairlineOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.55 : 0.10
    }

    /// The selected rail chip's own fill, following `ShelfPane`'s selected
    /// tile: a 0.18 fill plus a 1.5pt white-0.55 border. It used to borrow
    /// `surfaceHover`, which meant the selected tab and a hovered tab were the
    /// same colour and neither had an edge.
    static func selectedChipOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.30 : 0.18
    }

    @MainActor static var secondary: Color {
        Color.white.opacity(secondaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var tertiary: Color {
        Color.white.opacity(tertiaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surface: Color {
        Color.white.opacity(surfaceOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surfaceHover: Color {
        Color.white.opacity(surfaceHoverOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var hairline: Color {
        Color.white.opacity(hairlineOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var selectedChip: Color {
        Color.white.opacity(selectedChipOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    // MARK: - The Settings switch
    //
    // AppKit's switch draws its on-state only in a key window, and this panel
    // is never key outside Translate, so every switch in Settings drew in the
    // inactive style: on and off differed by which side the knob sat on and a
    // track a shade lighter (H-002, four personas, the privacy rows worst of
    // all). `PanelSwitchStyle` draws its own, from these.

    /// On is the person's own accent, the colour every switch on their Mac is
    /// on in. `controlAccentColor` resolves at draw time and does not ask
    /// whether the window is key, which is the whole point.
    static let switchOnFill = Color(nsColor: .controlAccentColor)

    /// Off is a faint light fill on the group, as the system's own off track
    /// is — not the recess it was (native pass, 2026-10-25: the probe's
    /// native off track measured 43/255 on black, a fill, and the dark well
    /// vanished into the black panel).
    ///
    /// White 0.08 rather than `quaternaryLabelColor`'s 0.10: on the group's
    /// 0.065 the 0.10 left purple, the dimmest accent macOS offers, at
    /// 2.99:1 against the off track, a hair under WCAG's 3:1 for telling the
    /// states apart; 0.08 holds it at 3.18. Increase Contrast keeps the dark
    /// well with its outline, because on that setting's brighter group a
    /// light fill cannot leave the accent its 3:1. `ContrastRampTests`
    /// measures all eight accents against both.
    static func switchOffGrey(increaseContrast: Bool) -> Double {
        let group = settingsGroupOpacity(increaseContrast: increaseContrast)
        return increaseContrast ? group * (1 - 0.50) : composite([group, 0.08])
    }

    @MainActor static var switchOffFill: Color {
        SystemAppearance.shared.increaseContrast ? Color.black.opacity(0.50) : Color.white.opacity(0.08)
    }

    /// The knob, white in both states as AppKit's is, with the faint shadow
    /// that keeps it a disc on the yellow accent, where white on yellow is
    /// barely an edge.
    static let switchKnob = Color.white
    static let switchKnobShadow = Color.black.opacity(0.3)

    /// Increase Contrast's defined border, on and off alike: the system draws
    /// one round its own controls with the setting on, and a switch that
    /// relies on fill alone is exactly what the setting is for.
    static let switchContrastOutline = Color.white.opacity(0.7)

    /// The grouped form's own switch on macOS 27: `NSSwitch` at `.mini`,
    /// 36 × 16 (native pass, 2026-10-25, measured in the probe; it was a
    /// hand-picked 30 × 17). The knob fills the track less a point each side.
    static let switchTrackSize = CGSize(width: 36, height: 16)
    static let switchKnobDiameter: CGFloat = 14

    // MARK: - The lock card's own ramp
    //
    // The card is not the panel and does not share its numbers. The panel is
    // white on its own black, where 0.46 is a readable label; the card floats
    // over whatever wallpaper is behind the shield, so its type runs brighter
    // to survive a pale one. That much was always deliberate.
    //
    // What was not deliberate is that the card carried those numbers as
    // literals — twenty-two of them — so Increase Contrast reached every label
    // in the panel and nothing at all here, on the one surface a person reads
    // from across a room. These are the same three roles the panel has, at the
    // card's own values, as functions of the setting like everything else.
    //
    // Where a literal fell between two roles it was rounded *up*, never down:
    // nothing on the card is dimmer than it was.

    /// Titles and the labels beside them. Was 0.55–0.62 in four places.
    ///
    /// 0.62 became 0.75 with F-003: over a pale cover the artist line was
    /// 1.76:1. The wash `LockCardLegibility` solves does most of that work; a
    /// brighter token is what lets it do it without darkening the cover as far.
    static func cardSecondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.85 : 0.75
    }

    /// Supporting text: the lyric status, the picker's rows, the volume
    /// glyphs. Was 0.40–0.50 in five places, and 0.40 over a bright wallpaper
    /// is barely there.
    ///
    /// 0.50 became 0.62 with F-003, for the same reason as `cardSecondary`:
    /// this is the token the cover's wash is solved against, so every point it
    /// gains is light a pale cover keeps.
    static func cardTertiaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.75 : 0.62
    }

    /// A filled shape that has to read as one: the artwork well, the unselected
    /// output dot. 0.08 was 1.14:1 over black — the same invisible-shape bug
    /// the panel's `surface` had, still sitting here.
    static func cardFillOpacity(increaseContrast: Bool) -> Double {
        // 0.16 rather than a tidier 0.14 for the same reason `surfaceOpacity`
        // is 0.16: it is the smallest round value clearing the 1.4 floor that
        // `ContrastRampTests` holds. 0.14 computes to 1.35:1 and is a shape
        // you cannot quite see.
        increaseContrast ? 0.28 : 0.16
    }

    /// The empty half of a bar — the seek track, the volume track.
    static func cardTrackOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.36 : 0.22
    }

    /// A 1pt edge on the card, not a fill.
    static func cardHairlineOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.55 : 0.25
    }

    @MainActor static var cardSecondary: Color {
        .white.opacity(cardSecondaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardTertiary: Color {
        .white.opacity(cardTertiaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardFill: Color {
        .white.opacity(cardFillOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardTrack: Color {
        .white.opacity(cardTrackOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardHairline: Color {
        .white.opacity(cardHairlineOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// Only for an action that destroys something, and only once it is armed.
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.40)
    /// A copy that landed, a tick that means done. The system green, named so
    /// the two places that flash it cannot drift to two greens.
    static let success = Color.green

    /// A Shelf tile whose disk is not plugged in draws its icon at this
    /// opacity, in greyscale (spec §8.4, `Shelf-Disk-Missing`): present enough
    /// to be recognised as the same tile, faded enough to read as out of reach
    /// before its caption is read. The caption itself stays at the tertiary
    /// ramp, which is what carries the words. 0.45 until 2026-10-15; the board
    /// draws 0.4 and takes the colour out as well, since a coloured icon at
    /// 0.45 still read as "available, a little shy".
    static let offlineThumbnailOpacity: Double = 0.4

    /// The smallest target a caption-sized control in the panel may offer.
    /// A word set at the caption role is 13 pt tall, and a button that is
    /// only its word left Shelf's Deselect a 44x13 sliver beside the
    /// destructive Clear (F-014). The width still follows the word; this is
    /// the floor under both.
    static let minimumHitSize = CGSize(width: 24, height: 20)

    /// A Shelf card under a held mouse button settles to this scale, so the
    /// press answers on the way down rather than on release (F-038): a card
    /// took the mouse-down with no sign of it until a drag image appeared or
    /// the click was let go. Small, because a card is a large target and a
    /// deeper dip reads as a button.
    static let pressScale: CGFloat = 0.97
    /// The same press under Reduce Motion, which asks for no change of size:
    /// the card dims to this opacity instead.
    static let pressDimOpacity: Double = 0.85
}

import AppKit
import Combine

/// What the lock card is made of (redesign 2026-10-15, spec §7.2).
///
/// Nothing above the login shield can sample the wallpaper, so the card draws
/// its own material. **Automatic**, the new default, is the cover's light —
/// today's Tinted recipe — at an opacity picked from how bright the wallpaper
/// behind the card is: a dark wallpaper needs a little more of it to keep the
/// card a card, a pale one needs more to keep white type readable over it, and
/// the middle of the road needs the least. It never goes below 0.84 (owner
/// decision 5): with no blur a lighter tint let Aerial's bright lines run
/// straight through the sung lyric, and the 2026-10-14 review found 0.56
/// illegible.
///
/// Pure, so the table the board prints (Aerial 0.90, Pro Black 0.88, Sonoma
/// 0.84, Sky Blue 0.86) is a test rather than a hope — `LockCardMaterialTests`.
enum LockCardMaterial {
    /// The least the card is ever opaque in Automatic (owner decision 5).
    static let floorAlpha = 0.84
    /// The most. Past it the card stops being "the cover's light" and becomes
    /// a black slab, which Solid already is.
    static let ceilingAlpha = 0.92
    /// The luminance the card assumes when it cannot know — a wallpaper behind
    /// a privacy gate, one the system composes, a file that will not decode.
    /// It is Sonoma's, the middle of the four measured, and it lands exactly on
    /// the floor: not knowing costs the card nothing it would not already have
    /// on an ordinary wallpaper, and never a prompt (`WallpaperTone`'s gate).
    static let unknownLuminance = 0.36

    /// `α = clamp(0.84 + 0.06·max(0, (0.30 − L)/0.27) + 0.12·max(0, (L − 0.36)/0.30), 0.84, 0.92)`
    /// for `L`, the mean luma (sRGB-encoded, as `WallpaperTone` measures it)
    /// behind the card. The first term lifts the card over a very dark
    /// wallpaper (Aerial is 0.03), the second over a bright one.
    static func automaticAlpha(luminance: Double?) -> Double {
        let l = min(max(luminance ?? unknownLuminance, 0), 1)
        let dark = 0.06 * max(0, (0.30 - l) / 0.27)
        let bright = 0.12 * max(0, (l - 0.36) / 0.30)
        return min(max(floorAlpha + dark + bright, floorAlpha), ceilingAlpha)
    }

    /// The style the card draws in. Reduce Transparency makes **every** style
    /// Solid — a translucent panel that stayed translucent would be the only
    /// frosted thing left on the screen — and otherwise the stored choice, or
    /// Automatic when nothing is stored.
    static func effectiveStyle(
        stored: NotchViewModel.LockCardStyle, reduceTransparency: Bool
    ) -> NotchViewModel.LockCardStyle {
        reduceTransparency ? .solid : stored
    }

    /// Transparent: black at 0.30 and a hairline (spec §7.2). The least it is;
    /// bright wallpaper raises it (`LockCardLegibility.transparentWash`).
    static let transparentAlpha = 0.30
    /// Tinted: the cover's light at 0.88 (spec §7.2).
    static let tintedAlpha = 0.88

    /// What the card is made of, drawn under its content.
    enum Layer: Equatable {
        /// The blurred cover, lit from behind (`LockScreenCard.coverLight`).
        case coverLight
        /// A dark neutral standing in for the cover's light when there is no
        /// cover (`Theme.lockCardSolid`).
        case neutralFill
        /// Black, nothing else, and a hairline: Transparent.
        case blackWash
        /// `#1C1C1E` and a hairline: Solid, and every style under Reduce
        /// Transparency.
        case solid
    }

    struct Decision: Equatable {
        var layer: Layer
        var alpha: Double
    }

    /// **The material, as a function of everything that chooses it** (spec §7.2).
    ///
    /// - Automatic: the cover's light at `automaticAlpha(luminance:)`.
    /// - Transparent: black at 0.30 or, where the wallpaper is bright or unknown,
    ///   the least more at which the dimmest type clears AA; hairline.
    /// - Tinted: the cover's light at 0.88.
    /// - Solid: `#1C1C1E`, hairline. Reduce Transparency makes every style this.
    ///
    /// **No cover is not no material** (review 2026-10-15). Automatic and Tinted
    /// are the cover's light, and a podcast or a browser tab has no cover: the
    /// view then drew nothing at all in its place, so the alpha — and the 0.84
    /// floor of owner decision 5 — was never applied, and the card was the bare
    /// drawn recipe over a shield it cannot sample, the exact thin pane the floor
    /// exists to prevent. The same alpha is laid as a dark neutral instead.
    ///
    /// Transparent under Increase Contrast is Solid: see-through is what that
    /// setting asks against. Before 2026-10-15 Transparent was the cover's light
    /// at 0.62 and Tinted at 1.0, neither of which the spec says.
    static func decision(
        style stored: NotchViewModel.LockCardStyle,
        hasArtwork: Bool,
        luminance: Double?,
        reduceTransparency: Bool,
        increaseContrast: Bool = false
    ) -> Decision {
        let light: Layer = hasArtwork ? .coverLight : .neutralFill
        switch effectiveStyle(stored: stored, reduceTransparency: reduceTransparency) {
        case .solid: return Decision(layer: .solid, alpha: 1)
        case .automatic: return Decision(layer: light, alpha: automaticAlpha(luminance: luminance))
        case .glass: return Decision(layer: light, alpha: tintedAlpha)
        case .clear:
            // 0.30 is the floor, not the answer: over a bright or unknown
            // wallpaper the dimmest type needs more black to clear AA
            // (`LockCardLegibility.transparentWash`, re-review 2026-10-15).
            return increaseContrast
                ? Decision(layer: .solid, alpha: 1)
                : Decision(layer: .blackWash, alpha: LockCardLegibility.transparentWash(luminance: luminance))
        }
    }
}

/// The wallpaper's brightness behind the lock card, measured once per lock.
///
/// The lock window asks at present, off the main actor: reading a 256 px
/// thumbnail of the picture is cheap and cached by file and date, but it is
/// still a file read and the lock screen is the wrong place to stall. Until the
/// answer lands — and for good when the wallpaper is behind a privacy gate —
/// the card is at its floor, which is what an unknown is (`unknownLuminance`).
@MainActor
final class LockCardToneModel: ObservableObject {
    /// The mean luma behind the card, or nil when it is not known.
    @Published private(set) var luminance: Double?

    /// How a picture is judged. Replaceable so a test can describe a wallpaper
    /// without owning one, and can prove a gated one is never opened.
    private let measure: @Sendable (URL, CGSize, CGRect) -> Double?
    private var generation = 0

    init(
        measure: @escaping @Sendable (URL, CGSize, CGRect) -> Double? = { url, screen, region in
            WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, region: region)
        }
    ) {
        self.measure = measure
    }

    /// The alpha Automatic draws at, for what is known so far.
    var alpha: Double { LockCardMaterial.automaticAlpha(luminance: luminance) }

    /// Looks at the wallpaper of `screen`. A nil URL — no picture named — is an
    /// unknown, and the luminance stays nil.
    func refresh(on screen: NSScreen, cardSize: CGSize) {
        refresh(
            wallpaper: NSWorkspace.shared.desktopImageURL(for: screen),
            screenSize: screen.frame.size, cardSize: cardSize
        )
    }

    /// The same by value, for a test. A stale answer for an earlier request —
    /// the display changed under a slow read — never lands.
    func refresh(wallpaper url: URL?, screenSize: CGSize, cardSize: CGSize) {
        generation += 1
        let mine = generation
        guard let url else {
            luminance = nil
            return
        }
        let region = WallpaperTone.cardRegion(screenSize: screenSize, cardSize: cardSize)
        let measure = measure
        Task { [weak self] in
            let answer = await Task.detached(priority: .utility) {
                measure(url, screenSize, region)
            }.value
            guard let self, self.generation == mine, self.luminance != answer else { return }
            self.luminance = answer
        }
    }
}

extension LockCardMaterial {
    /// The shadow behind every mark on the card, by what is **drawn** (re-review
    /// 2026-10-15). It keyed off the stored style, so under Increase Contrast a
    /// Transparent choice drew a Solid panel with Transparent's 0.5 shadow. A
    /// panel that is opaque carries none; the black wash, through which the
    /// wallpaper shows, carries the most; the cover's light a little.
    static func textShadowOpacity(for layer: Layer) -> Double {
        switch layer {
        case .solid: return 0
        case .blackWash: return 0.5
        case .coverLight, .neutralFill: return 0.35
        }
    }
}

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

    /// How opaque the cover's light is drawn: the wallpaper-driven alpha for
    /// Automatic, Transparent's 0.62 (opaque again under Increase Contrast,
    /// which asks against see-through), and full for Tinted, as it always was.
    static func coverLightOpacity(
        style: NotchViewModel.LockCardStyle, alpha: Double, increaseContrast: Bool
    ) -> Double {
        switch style {
        case .automatic: return alpha
        case .clear: return increaseContrast ? 1 : 0.62
        case .glass, .solid: return 1
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

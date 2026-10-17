import CoreGraphics
import Foundation

extension NotchViewModel {
    /// What the open island shows (spec §19.1, §19.6–§19.8, §19.16). It
    /// replaced the five tabs and their rail (§19.11): a click opens what the
    /// island shows, and every other way in names the surface it wants.
    ///
    /// Two of the eight are presented rather than chosen: the drop surface
    /// while files are dragged to the notch (`isDropTargeted`), and the welcome
    /// for one launch (`isShowingWelcome`). Each lies over the surface chosen
    /// underneath, which comes back when it ends; `open(_:)` refuses both.
    ///
    /// Tools, the small grid a click on the bare notch used to open, is
    /// withdrawn (§19.16): with every place one swipe or one dot away, a fourth
    /// road to the same places was noise.
    enum Surface: String, CaseIterable, Identifiable {
        case player, stage, tray, drop, clipboard, translate, settings, welcome
        var id: String { rawValue }

        /// The surfaces somebody can be sent to.
        static let reachable: [Surface] = [.player, .stage, .tray, .clipboard, .translate, .settings]

        /// The four pages, in their one order, left to right (§19.16). The
        /// order never changes and no page is ever missing — Music with no
        /// song is the empty player, an empty Shelf says how to fill it — so
        /// a swipe always lands where it landed last time. The stage and
        /// Settings sit a level below a page and are not in the row.
        static let pages: [Surface] = [.player, .tray, .clipboard, .translate]

        /// Where this surface sits in `pages`, or nil for one that is not a page.
        var pageIndex: Int? { Self.pages.firstIndex(of: self) }
        var isPage: Bool { pageIndex != nil }

        /// The name the island's value and the surface's group carry for
        /// VoiceOver.
        var title: String {
            switch self {
            case .player: return localized("Music")
            case .stage: return localized("Lyrics")
            case .tray, .drop: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .translate: return localized("Translate")
            case .settings: return localized("Settings")
            case .welcome: return localized("Welcome")
            }
        }

        /// The glyph its header row leads with, where it has one (§19.8).
        var symbol: String? {
            switch self {
            case .clipboard: return "doc.on.clipboard"
            case .translate: return "translate"
            case .settings: return "gearshape"
            case .tray: return "tray.full.fill"
            case .player, .stage, .drop, .welcome: return nil
            }
        }

        /// Surfaces with a field that has the keyboard when they open: Translate,
        /// and Clipboard, whose search field types from the first key (§19.8).
        var takesKeyboard: Bool { self == .clipboard || self == .translate }

        /// The surfaces that carry the gear at (`bw − 46`, 6) (§19.16): every
        /// page and the stage, where the Tools button stood, and Settings,
        /// where it stands lit and goes back.
        var hasGear: Bool {
            switch self {
            case .player, .stage, .tray, .clipboard, .translate, .settings: return true
            case .drop, .welcome: return false
            }
        }

        /// The shoulder: 24 for the Shelf's two, 34 for every other surface.
        var topRadius: CGFloat {
            switch self {
            case .tray, .drop: return 24
            default: return 34
            }
        }

        var bottomRadius: CGFloat {
            switch self {
            case .tray, .drop: return 34
            default: return 44
            }
        }
    }

    /// What a click on the island does (§19.1's first table).
    enum IslandClick: Equatable {
        /// Opens the surface.
        case open(Surface)
        /// An alert folds, and the island returns to what is live.
        case foldAlert
    }

    /// - Parameter activity: what the island shows.
    /// - Parameter live: the live activity under it, which a folded alert
    ///   gives the island back to.
    /// - Parameter hasTrack: whether there is a song at all, playing or paused.
    /// - Parameter lastPage: the page last shown since launch, which the bare
    ///   notch with no song opens (§19.16).
    nonisolated static func click(
        on activity: IslandActivity, live: IslandActivity, hasTrack: Bool = false, lastPage: Surface = .player
    ) -> IslandClick {
        switch activity {
        case .hud, .ambient: return .foldAlert
        case .peek: return .open(.player)
        case .music, .shelf, .none: return .open(openTarget(live: live, hasTrack: hasTrack, lastPage: lastPage))
        }
    }

    /// What ⌃⌥⌘I, Open on Hover and a click on a live activity open: the
    /// player for the song, the tray for the Shelf, and on the bare notch with
    /// no song the page last shown since launch — Music at launch (§19.16).
    /// That used to be Tools, which is withdrawn; the page somebody was last
    /// on is where they were, so it is where the notch takes them back to.
    ///
    /// A song paused long enough for the island to fold is not live (§19.1),
    /// but it is still a song: the bare notch over it opens the player, paused,
    /// where play is one click away, whatever page was last shown.
    nonisolated static func openTarget(
        live: IslandActivity, hasTrack: Bool = false, lastPage: Surface = .player
    ) -> Surface {
        switch live {
        case .peek, .music: return .player
        case .shelf: return .tray
        case .hud, .ambient, .none: return hasTrack ? .player : (lastPage.isPage ? lastPage : .player)
        }
    }
}

/// Each surface's one size (spec §19.6–§19.8). Positions on the player and the
/// tray are the reference's, measured from the shape's left edge with its
/// shoulders (§19.2), so their bodies are the reference less two shoulders; the
/// summoned surfaces are written in the body's own coordinates and run the
/// panel's width (`bw`). Every height is the reference's at a 38 pt notch, and
/// moves with the notch as the expanded alerts' do, so content keeps its
/// distance from the header row on every Mac. A page is `pageDotsBand` taller
/// than its reference, for the row of dots under it (§19.16); nothing else on
/// it moves.
enum SurfaceLayout {
    static let referenceNotchHeight: CGFloat = 38
    static let playerReference = CGSize(width: 425.4, height: 198)
    static let trayReference = CGSize(width: 433.3, height: 158)
    static let stageHeight: CGFloat = 400
    static let dropHeight: CGFloat = 176
    static let clipboardHeight: CGFloat = 300
    static let translateHeight: CGFloat = 268
    static let settingsHeight: CGFloat = 400
    /// §19.2: an expanded shape is never narrower than the notch plus 20.
    static let widthPastTheNotch: CGFloat = 20
    /// The band under every page that holds its dots (§19.16). Added to the
    /// page rather than squeezed out of it: the player and the tray are
    /// measured shapes, and Clipboard's last row and Translate's cards would
    /// otherwise sit on the dots.
    static let pageDotsBand: CGFloat = 16

    /// The band's share of `surface`'s height: the band on a page, nothing
    /// anywhere else.
    static func dotsBand(for surface: NotchViewModel.Surface) -> CGFloat {
        surface.isPage ? pageDotsBand : 0
    }

    /// A reference y at a 38 pt notch, on this notch.
    static func y(_ spec: CGFloat, notchHeight: CGFloat) -> CGFloat {
        spec - referenceNotchHeight + notchHeight
    }

    /// A reference frame, in the content's own coordinates: the content starts
    /// under the header row, so every y below it is the reference's less 38 on
    /// any notch, and x is the body's own — there is no rail to the left of it
    /// any more.
    static func inContent(_ spec: CGRect) -> CGRect {
        spec.offsetBy(dx: 0, dy: -referenceNotchHeight)
    }

    /// The same for a body frame measured on this notch, which is what the
    /// summoned surfaces' layouts hand out.
    static func inContent(_ body: CGRect, headerHeight: CGFloat) -> CGRect {
        body.offsetBy(dx: 0, dy: -headerHeight)
    }

    /// A control in the header row, drawn at `spec`'s size and centred on the
    /// row whatever its height: the reference centres everything on a 38 pt
    /// row (a 26 pt well at y 6, a 16 pt line at 11), and a 32 pt notch keeps
    /// the centring rather than the offset.
    static func headerCentreY(notchHeight: CGFloat) -> CGFloat { notchHeight / 2 }

    /// The gear and every other header tool: 26 × 26, the gear ending 20
    /// from the body's right edge (§19.8, §19.16).
    static let headerToolSide: CGFloat = 26
    static func gearX(bodyWidth: CGFloat) -> CGFloat { bodyWidth - 46 }
    /// The glyph-and-title pair's leading edge on a summoned surface.
    static let headerTitleLeading: CGFloat = 20

    /// The outline between pages (§19.16): at `position` along `pages`, each
    /// page's own size at rest, and the two either side of it mixed by the
    /// travel between them, so the outline's width and height move in step
    /// with the content. A rubber band past an end keeps the end page's size.
    static func travelSize(
        pages: [NotchViewModel.Surface], position: CGFloat, bodyWidth: CGFloat, notch: CGSize
    ) -> CGSize {
        let last = pages.count - 1
        let clamped = min(max(position, 0), CGFloat(last))
        let lower = min(Int(clamped.rounded(.down)), last)
        let leaving = bodySize(for: pages[lower], bodyWidth: bodyWidth, notch: notch)
        guard lower < last else { return leaving }
        let arriving = bodySize(for: pages[lower + 1], bodyWidth: bodyWidth, notch: notch)
        let fraction = clamped - CGFloat(lower)
        return CGSize(
            width: leaving.width + (arriving.width - leaving.width) * fraction,
            height: leaving.height + (arriving.height - leaving.height) * fraction
        )
    }

    static func bodySize(
        for surface: NotchViewModel.Surface, bodyWidth bw: CGFloat, notch: CGSize
    ) -> CGSize {
        let h = notch.height
        let floor = notch.width + widthPastTheNotch
        let band = dotsBand(for: surface)
        switch surface {
        case .player:
            return CGSize(
                width: max(playerReference.width - 2 * surface.topRadius, floor),
                height: y(playerReference.height, notchHeight: h) + band
            )
        case .tray:
            return CGSize(
                width: max(ShelfLayout.bodyWidth(notchWidth: notch.width), floor),
                height: y(trayReference.height, notchHeight: h) + band
            )
        case .stage: return CGSize(width: bw, height: y(stageHeight, notchHeight: h))
        case .drop: return CGSize(width: bw, height: y(dropHeight, notchHeight: h))
        case .clipboard: return CGSize(width: bw, height: y(clipboardHeight, notchHeight: h) + band)
        case .translate: return CGSize(width: bw, height: y(translateHeight, notchHeight: h) + band)
        case .settings: return CGSize(width: bw, height: y(settingsHeight, notchHeight: h))
        case .welcome: return CGSize(width: bw, height: NotchMetrics.standardBodyHeight)
        }
    }
}

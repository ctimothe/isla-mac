import Combine
import Foundation
import CoreGraphics

/// The level the volume and brightness pop-up shows *this instant*, kept apart
/// from the view model.
///
/// A held key presses again every 30 to 35 ms. The level used to be part of
/// `NotchViewModel.hud`, a `@Published` of the whole view model, so every press
/// announced a change to everything that watches the view model and re-ran the
/// island's entire body — the song's header, the outline's state, every pane's
/// modifiers — to move a bar by a few points (owner, 2026-10-25: "it kind of
/// lags a little bit … as light as the native macOS one"). The pop-up's
/// symbol, level and percent now live here, and only the views that draw them
/// (`HUDPillContent`, `HUDStripContent`) observe it. The view model keeps just
/// whether a pop-up is up (`hudShown`, `hudStripShown`), which changes on
/// arrival and on the fold and on no press in between.
///
/// It keeps its last moment through the fold on purpose: a view that is
/// leaving still has to draw something while its transition runs, and the
/// next arrival replaces it before the first frame.
@MainActor
final class HUDLiveLevel: ObservableObject {
    @Published private(set) var moment: HUDMoment?

    /// Stores `new` and tells the pop-up's views, unless it is what they
    /// already draw: a key held at the end of its range repeats the same level
    /// and moves nothing.
    func update(_ new: HUDMoment) {
        if moment != new { moment = new }
    }
}

/// Where the level indicator sits while the panel is open (redesign spec §19.5
/// d amendment, 2026-10-25; research `2026-10-25-hud-over-open-panel.md`,
/// Option A): a black capsule 32 pt tall, 6 pt under the open body, centred on
/// the notch's axis, holding the pop-up's symbol, bar and percent.
///
/// It lives inside the window the panel is already cut to — the window is
/// never resized — in the transparent band under the tallest body, and it is
/// not part of the clickable region (`NotchRootView.activeRect`). Pure, so the
/// fit is a test, for every notch height and every surface.
enum HUDStripLayout {
    static let height: CGFloat = 32
    /// Between the body's bottom edge and the capsule's top.
    static let gap: CGFloat = 6
    /// Never wider than the body less the curve of its two bottom corners, so
    /// the capsule sits inside the panel's own lines (concentric margins).
    static let preferredWidth: CGFloat = 220
    static let minimumWidth: CGFloat = 140

    /// The bar is thinner than the shut pop-up's 8 pt: the capsule is a strip,
    /// not a second card.
    static let barHeight: CGFloat = 6
    static let barRadius: CGFloat = 3
    static let symbolSize = CGSize(width: 20, height: 14)
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 14
    static let spacing: CGFloat = 10
    /// Room for "100" in SF Pro Rounded 14 with tabular digits.
    static let numberWidth: CGFloat = 32
    static let numberSize: CGFloat = HUDLayout.numberSize

    static func width(bodyWidth: CGFloat, bottomRadius: CGFloat) -> CGFloat {
        max(minimumWidth, min(preferredWidth, bodyWidth - 2 * bottomRadius))
    }

    /// The capsule in the window's own coordinates, origin top-left (the
    /// island is pinned to the window's top edge). Held inside the window
    /// whatever the body's height: past the notch height that fits, it would
    /// sit over the body's last points rather than outside the window
    /// (`fits` says which).
    static func frame(bodySize: CGSize, bottomRadius: CGFloat, windowSize: CGSize) -> CGRect {
        let width = width(bodyWidth: bodySize.width, bottomRadius: bottomRadius)
        let y = min(bodySize.height + gap, windowSize.height - height)
        return CGRect(x: (windowSize.width - width) / 2, y: y, width: width, height: height)
    }

    /// Whether the capsule clears the body and stays inside the window.
    static func fits(bodyHeight: CGFloat, windowHeight: CGFloat) -> Bool {
        bodyHeight + gap + height <= windowHeight
    }

    /// The tallest body any surface asks for on a notch `notchHeight` tall,
    /// at any panel width.
    static func tallestBody(notch: CGSize, bodyWidth: CGFloat) -> CGFloat {
        NotchViewModel.Surface.allCases
            .map { SurfaceLayout.bodySize(for: $0, bodyWidth: bodyWidth, notch: notch).height }
            .max() ?? 0
    }

    /// The tallest notch the capsule still fits under, on the window's height:
    /// `tallestBody` grows one point per point of notch (`SurfaceLayout.y`), so
    /// this is the window less the strip, less Settings' height at a 38 pt
    /// reference notch, plus that 38.
    static func tallestNotchThatFits(windowHeight: CGFloat) -> CGFloat {
        windowHeight - gap - height - SurfaceLayout.settingsHeight + SurfaceLayout.referenceNotchHeight
    }
}

/// What the capsule under the open panel carries when it is not the level
/// (spec §19.5 d, amended 2026-10-26; owner: "when the island is open and I
/// charge, it doesn't show under the island — every HUD should"): the
/// charger, headphones connecting, and the island's confirmations. Before,
/// each of them waited for the panel to close — a second for the charger and
/// headphones, five for a confirmation — and was usually never seen.
///
/// Same capsule, same placement under the drawn outline, same arrival and
/// fold as the level's; one thing at a time, by the island's own ranks
/// (`IslandAlertQueue`), with the level above everything.
enum StripNotice: Equatable {
    case ambient(AmbientActivity)
    case confirmation(IslandConfirmation)

    /// The island alert it stands for, for the ranks.
    var activity: IslandActivity {
        switch self {
        case .ambient(let ambient): return .ambient(ambient)
        case .confirmation(let confirmation): return .confirmation(confirmation)
        }
    }

    /// The notice an alert from the queue becomes, or nil for one the
    /// capsule does not carry (the level is `hudStrip`; the update alert has
    /// buttons and waits for the shut island; the peek is the song's).
    init?(_ activity: IslandActivity) {
        switch activity {
        case .ambient(let ambient): self = .ambient(ambient)
        case .confirmation(let confirmation): self = .confirmation(confirmation)
        default: return nil
        }
    }

    /// The panel closing within this long of the notice's arrival hands it to
    /// the shut island for its whole hold. Return in the Clipboard copies and
    /// closes in one press: its "Copied" reached the capsule and left with the
    /// panel in the same moment, and nobody saw it anywhere. A notice that
    /// stood longer than this was read, and goes with the panel.
    static let handBackWindow: TimeInterval = 0.6

    /// Pure, so the rule is a test.
    static func handsBack(shownFor elapsed: TimeInterval) -> Bool {
        elapsed < handBackWindow
    }
}

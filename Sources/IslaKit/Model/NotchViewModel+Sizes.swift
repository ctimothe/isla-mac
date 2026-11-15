import AppKit
import Combine
import UniformTypeIdentifiers

/// The sizes and corner radii of the shut and the open island. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    /// Body the presented surface takes when open — asked whether it is open
    /// yet or not.
    ///
    /// Separate from `bodySize` because the rects are cut one step before the
    /// panel is marked open: `setOpen` grows the interactive area first, so
    /// the pointer never falls through a region the animation has not covered.
    /// Reading a size that returns the notch until `isOpen` flips would hand
    /// that step the collapsed size and leave the whole body drawn but deaf to
    /// the pointer.
    ///
    /// One size per surface (spec §19.6–§19.8, `SurfaceLayout`). The window is
    /// cut for the tallest once and never resized, so only the rects and the
    /// drawn body follow this.
    ///
    /// While the pages travel (§19.16) it is every page the leg can draw the
    /// outline at, together: the drawn outline moves under the fingers
    /// between two sizes, and the clickable region is cut once for all of
    /// them rather than sixty times a second. It returns to the page's own
    /// when the leg ends.
    var openBodySize: CGSize {
        if let leg = travellingLeg {
            return leg.reachable.map(openSize(of:)).reduce(CGSize.zero) {
                CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
            }
        }
        return openSize(of: presented)
    }

    /// One surface's open body on this display.
    func openSize(of surface: Surface) -> CGSize {
        SurfaceLayout.bodySize(for: surface, bodyWidth: geometry.expandedSize.width, notch: geometry.notchSize)
    }

    /// The leg the pages are on, while what is presented is a page: the drop
    /// surface or the welcome laid over the pages leaves them at rest under it.
    var travellingLeg: PageTravel.Leg? {
        presented.isPage ? pageTravel.leg : nil
    }

    /// The outline as drawn while open: the presented surface's body, or
    /// between two pages the mix the travel has reached.
    var drawnOpenBodySize: CGSize {
        guard let leg = travellingLeg else { return openBodySize }
        return SurfaceLayout.travelSize(
            pages: leg.strip.pages, position: leg.drawnPosition,
            bodyWidth: geometry.expandedSize.width, notch: geometry.notchSize
        )
    }

    /// The open shape's shoulder and bottom corner, for the presented surface,
    /// and mixed between two pages as their sizes are.
    var openTopRadius: CGFloat { travelled(\.topRadius) }
    var openBottomRadius: CGFloat { travelled(\.bottomRadius) }

    private func travelled(_ radius: KeyPath<Surface, CGFloat>) -> CGFloat {
        guard let leg = travellingLeg else { return presented[keyPath: radius] }
        let last = leg.strip.lastIndex
        let position = leg.drawnPosition
        let lower = min(Int(position.rounded(.down)), last)
        let leaving = leg.strip.pages[lower][keyPath: radius]
        guard lower < last else { return leaving }
        let arriving = leg.strip.pages[lower + 1][keyPath: radius]
        return leaving + (arriving - leaving) * (position - CGFloat(lower))
    }

    /// Size of the visible body for the current state: the open body, or the
    /// shape of the one activity the island shows (`IslandActivity`).
    var bodySize: CGSize {
        if isOpen || isDropTargeted { return drawnOpenBodySize }
        let activity = self.activity
        let media = compactMediaActivity.bodySize(
            notchSize: geometry.notchSize,
            // The body the panel would open to, so the pill can never be wider
            // than the panel it turns into.
            bodyWidth: geometry.expandedSize.width
        )
        switch activity {
        case .hud(let hud):
            // Over the lock screen the pop-up keeps to the pill's own height
            // (spec §3.7, amended 2026-10-26): the 103 pt alert would hang
            // over the lock screen's clock.
            if isLockedPresentation {
                return LockedHUDLayout.bodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
            }
            return Self.hudBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        case .confirmation(let confirmation):
            return ConfirmationLayout.bodySize(
                title: confirmation.title, notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width
            )
        case .ambient(let ambient):
            return Self.ambientBodySize(ambient, notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        case .update:
            return Self.updateBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        case .shelf:
            return Self.shelfBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        case .live(let live):
            return LiveActivityLayout.bodySize(
                live, expanded: showsLiveControls, notchSize: geometry.notchSize,
                bodyWidth: geometry.expandedSize.width
            )
        case .peek:
            return Self.newTrackBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        case .music, .none:
            return media
        }
    }

    /// A new track: the pop-up's own body, under the notch (spec §3.5,
    /// amended 2026-11-15). Pure, so the arithmetic has tests.
    nonisolated static func newTrackBodySize(notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        NewTrackAlertLayout.shape.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
    }

    /// The Shelf as the island's live activity: the notch plus 75, the notch's
    /// height, never wider than the panel. Pure, so the arithmetic has tests.
    nonisolated static func shelfBodySize(notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        CGSize(width: min(notchSize.width + NotchMetrics.compactShelfExtension, bodyWidth), height: notchSize.height)
    }

    /// The pop-up: an expanded alert, the reference's 245.4 × 103 on a notch
    /// of any size (spec §19.5 d, `ExpandedAlertShape`). It no longer widens
    /// to the music pill it replaces: that pill is gone, not under it (§19.1).
    /// Pure, so the arithmetic has tests.
    nonisolated static func hudBodySize(notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        ExpandedAlertShape.volume.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
    }

    /// The update alert: the reference's 335.4 × 158 on a notch of any size
    /// (spec §19.5 f). Pure, so the arithmetic has tests.
    nonisolated static func updateBodySize(notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        ExpandedAlertShape.update.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
    }

    /// The charger, compact: the notch plus 180 at the notch's height (§19.4).
    /// Headphones, expanded: the reference's 370.3 × 95 (§19.5 c). Never wider
    /// than the panel. Pure, so the arithmetic has tests.
    nonisolated static func ambientBodySize(
        _ ambient: AmbientActivity, notchSize: CGSize, bodyWidth: CGFloat
    ) -> CGSize {
        switch ambient {
        case .charging:
            return CGSize(
                width: min(notchSize.width + NotchMetrics.compactChargingExtension, bodyWidth),
                height: notchSize.height
            )
        case .headphones:
            return ExpandedAlertShape.headphones.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
        case .batteryLow:
            return ExpandedAlertShape.batteryLow.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
        case .batteryFull:
            return ExpandedAlertShape.batteryFull.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
        case .timerDone:
            return LiveActivityLayout.doneShape.bodySize(notchSize: notchSize, bodyWidth: bodyWidth)
        }
    }

    /// The shut island's shoulder: the radius its shape and hit rects take
    /// for what it shows (`IslandShapeRadii`).
    var closedTopRadius: CGFloat { IslandShapeRadii.closed(for: activity, liveControls: showsLiveControls).top }
}

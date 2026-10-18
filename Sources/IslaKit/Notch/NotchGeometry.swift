import AppKit

/// Physical description of the notch (or a synthetic one on Macs without it)
/// plus every derived rect the panel needs, all in screen coordinates.
struct NotchGeometry {
    let screen: NSScreen
    /// Size of the physical notch in points.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat
    /// True when the display actually has a notch cut into it.
    let isPhysical: Bool

    /// Size of the fully expanded panel body. Held constant across every Mac:
    /// letting it follow the header made two people on the very same model
    /// see two different heights, just from different display-scaling
    /// settings — 38 pt against 32 for the same physical notch, an 11 pt
    /// spread from one slider (#27). The surfaces' heights move with the notch
    /// instead (`SurfaceLayout.y`), so their content keeps its distance from
    /// the header row.
    /// Read once, when the geometry is built. Settings rebuilds the panel rather
    /// than nudging it, which is the same path a display change takes and the
    /// only one known to leave every rect consistent.
    let expandedSize = NotchMetrics.body(width: NotchViewModel.bodyWidth)

    /// The tallest body the window is cut for.
    ///
    /// No tab asks for it any more — the teleprompter that did was removed on
    /// 2026-08-22 — but the window is still cut to it, because the window is
    /// never resized and every rect below is written against that height.
    /// Same width as the standard body, so nothing ever changed shape sideways.
    static let tallBodyHeight = NotchMetrics.tallestBody.height
    /// Tallest body any tab can ask for. The window is cut to this once and
    /// never resized: it is transparent outside the visible panel, and what is
    /// clickable is decided separately by the active rect.
    var maxBodyHeight: CGFloat { max(expandedSize.height, Self.tallBodyHeight) }

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// Nil while the system reports no screens at all. That window is real:
    /// `NSScreen.screens` is momentarily empty during display renegotiation —
    /// unplugging the only display of a clamshell Mac — and
    /// `didChangeScreenParametersNotification` fires exactly then, so this used
    /// to be an index-out-of-range crash on a supported gesture. There is no
    /// geometry to invent without a display; callers wait for the next
    /// notification instead.
    /// What a display says about its own cutout right now.
    enum NotchReading: Equatable {
        case physical(size: CGSize, centerX: CGFloat)
        case none
    }

    /// What a display said about its cutout last time it was asked.
    struct RememberedNotch: Equatable {
        let frame: CGRect
        let size: CGSize
        let centerX: CGFloat
    }

    /// Whether to believe a display that has stopped reporting its notch.
    ///
    /// `safeAreaInsets` reads zero for a beat across reconfigurations — waking,
    /// unlocking, a mode change, another display arriving — on Macs whose
    /// cutout has not moved. Taken at face value, the panel rebuilds around a
    /// synthetic notch: a smaller pill anchored to the middle of the screen
    /// instead of to the hardware, which then stands until some later
    /// notification happens to correct it. Locking and unlocking is the one
    /// that reliably does, which is how the bug presented.
    ///
    /// So a zero reading only counts when something about the display actually
    /// changed. Same frame as when the cutout was last seen means the hardware
    /// is the same hardware, and the reading is the thing that is wrong. A
    /// different frame is a real mode change — non-HiDPI modes genuinely stop
    /// vending a safe area, and there a drawn notch is correct.
    static func decide(
        reading: NotchReading,
        screenFrame: CGRect,
        remembered: RememberedNotch?
    ) -> NotchReading {
        if case .physical = reading { return reading }
        guard let remembered, remembered.frame == screenFrame else { return .none }
        return .physical(size: remembered.size, centerX: remembered.centerX)
    }

    /// The last cutout each display admitted to, by display id.
    @MainActor private static var rememberedNotches: [CGDirectDisplayID: RememberedNotch] = [:]

    @MainActor private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    @MainActor
    static func current() -> NotchGeometry? {
        // `NSScreen.main` tracks the key window, and this panel is a
        // non-activating one that never becomes key or main — so `.main` here
        // would be meaningless and nondeterministic rather than a real
        // fallback. A display remembered as notched counts as notched even
        // while it is briefly saying otherwise, or a glitched reading would
        // also move the island to whichever screen happens to be first.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first(where: { screen in
                displayID(of: screen).flatMap { rememberedNotches[$0] }?.frame == screen.frame
            })
            ?? NSScreen.screens.first else { return nil }

        let live: NotchReading
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            live = .physical(
                size: CGSize(width: width, height: screen.safeAreaInsets.top),
                centerX: screen.frame.minX + left.width + width / 2
            )
        } else {
            live = .none
        }

        let id = displayID(of: screen)
        let remembered = id.flatMap { rememberedNotches[$0] }
        switch decide(reading: live, screenFrame: screen.frame, remembered: remembered) {
        case .physical(let size, let centerX):
            if let id {
                rememberedNotches[id] = RememberedNotch(frame: screen.frame, size: size, centerX: centerX)
            }
            return NotchGeometry(
                screen: screen,
                notchSize: size,
                notchCenterX: centerX,
                isPhysical: true
            )
        case .none:
            if let id { rememberedNotches[id] = nil }
        }

        // No notch: pretend there is one the size of a typical MacBook cutout so
        // the app still works on external displays and pre-2021 machines.
        //
        // The height has to be the menu bar's own, not `NSStatusBar.thickness`:
        // the two disagree by several points (22 against 30 on a 13" M1 running
        // macOS 26), and the shape is drawn filled black, so anything short of
        // the bar's height reads as a tab stuck onto the menu bar rather than a
        // cutout of it. `visibleFrame` is what the menu bar actually took —
        // measured, not assumed. It collapses to zero when the bar auto-hides,
        // which is what the floor is for.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screen: screen,
            notchSize: Self.syntheticNotchSize(
                menuBarHeight: menuBarHeight, statusBarThickness: NSStatusBar.system.thickness
            ),
            notchCenterX: screen.frame.midX,
            isPhysical: false
        )
    }

    /// How wide the island drawn on a display with no cutout rests (spec §3.8).
    /// 180 until 2026-10-15; 200 sits the compact island's two 40 pt wings on a
    /// pill that reads as a deliberate shape on a menu bar rather than a tab, and
    /// is still narrower than the 14-inch notch it stands in for.
    static let syntheticNotchWidth: CGFloat = 200

    /// The size of the island on a display with no notch: 200 wide, and the
    /// menu bar's own height — never under 24 — so the black reads as a cutout
    /// of the bar. Pure, so the width and the height rule are tests.
    static func syntheticNotchSize(menuBarHeight: CGFloat, statusBarThickness: CGFloat) -> CGSize {
        CGSize(width: syntheticNotchWidth, height: max(menuBarHeight, statusBarThickness, 24))
    }

    /// True when nothing that affects the panel has moved. Screen-parameter
    /// notifications fire for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state
    /// and the selected tab.
    func matches(_ other: NotchGeometry) -> Bool {
        screen.frame == other.screen.frame
            && notchSize == other.notchSize
            && notchCenterX == other.notchCenterX
            && isPhysical == other.isPhysical
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        // The *widest* body, not this one. The window is cut once for the
        // largest the body can ever be and never resized: a narrower setting
        // leaves more of it transparent, and nothing moves.
        let size = CGSize(
            width: NotchMetrics.maximumBodyWidth + windowPadding.left + windowPadding.right,
            height: maxBodyHeight + windowPadding.bottom
        )
        // The assert is a debug-only consistency check that the padding math
        // still agrees with the constant — it must not be what the contract
        // depends on, since assert() is stripped from Release builds.
        assert(size == NotchMetrics.maximumWindow)
        return NotchMetrics.maximumWindow
    }

    /// Panel frame in global screen coordinates, flush with the top of the display.
    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screen.frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `screen.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    ///
    /// Only where the top edge is really an edge. With a second display arranged
    /// directly above, the two points past `maxY` are inside *that* display, and
    /// a pointer working along its bottom edge would open — and hold open — the
    /// panel on the screen below it.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screen.frame.maxY, !hasScreenAbove(spanning: rect) else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Whether another display covers any part of the strip this rect would
    /// grow into.
    ///
    /// Asked about the rect's own horizontal span, not the notch's. The rects
    /// that go through here differ by hundreds of points — the warm zone is the
    /// full width of the screen — so a probe fixed to the notch's ~200 pt said
    /// "nothing above" for a display offset sideways, and the wider rects were
    /// grown into it anyway.
    private func hasScreenAbove(spanning rect: CGRect) -> Bool {
        let strip = CGRect(x: rect.minX, y: screen.frame.maxY, width: max(rect.width, 1), height: 2)
        return NSScreen.screens.contains { $0.frame != screen.frame && $0.frame.intersects(strip) }
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    /// The compact island's rect in the coordinate space a SwiftUI gesture
    /// reports its clicks in.
    ///
    /// The same rect `NotchController.applyActiveRect` hands to
    /// `NotchRootView.activeRect`, expressed the other way up. It exists because
    /// the two layers disagreed and one of them was silently wrong: the panel's
    /// click gesture is attached to a view that fills the whole window, so its
    /// `.local` space is the window — and the rect it tested against was pinned
    /// at that window's origin while the island is centred in it. The overlap
    /// was the island's left edge. With a track playing on a 185 pt notch, the
    /// left 34 % opened the panel and the right 66 % did nothing; with nothing
    /// playing there was no overlap at all and the island was dead everywhere.
    /// `activeRect` was right the whole time, which is why it let the clicks
    /// through to be thrown away here, and why hovering — which goes through
    /// `PointerWatcher` instead — never showed it.
    ///
    /// `contentRect` measures up from the bottom, the way AppKit does. SwiftUI
    /// measures down from the top, and the island is pinned to the top edge, so
    /// only the horizontal half of that rect carries over.
    func compactGestureRect(for bodySize: CGSize, topRadius: CGFloat) -> CGRect {
        let rect = contentRect(for: bodySize).insetBy(dx: -topRadius, dy: 0)
        return CGRect(x: rect.minX, y: 0, width: rect.width, height: bodySize.height)
    }

    /// The Shelf's bubble beside a compact island `islandWidth` wide (spec
    /// §19.7), its whole shape, in AppKit window coordinates — the space
    /// `NotchRootView.bubbleRect` is in.
    func bubbleRect(islandWidth: CGFloat, height: CGFloat, count: Int) -> CGRect {
        let width = IslandBubbleLayout.width(count: count)
        return CGRect(
            x: windowSize.width / 2 + IslandBubbleLayout.centreOffset(islandWidth: islandWidth, count: count)
                - width / 2,
            y: windowSize.height - height,
            width: width,
            height: height
        )
    }

    /// The same, in the coordinates a SwiftUI gesture reports (top-left
    /// origin), as `compactGestureRect` is the island's.
    func bubbleGestureRect(islandWidth: CGFloat, height: CGFloat, count: Int) -> CGRect {
        let rect = bubbleRect(islandWidth: islandWidth, height: height, count: count)
        return CGRect(x: rect.minX, y: 0, width: rect.width, height: height)
    }

    /// The same on screen, for the pointer sampler.
    func bubbleScreenRect(islandWidth: CGFloat, height: CGFloat, count: Int) -> CGRect {
        includingTopEdge(
            bubbleRect(islandWidth: islandWidth, height: height, count: count)
                .offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
        )
    }

    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Depth of the collapsed target, measured down from the top edge.
    ///
    /// The drawn depth, on every display. `NotchShape` fills black
    /// unconditionally (`NotchContentView.swift:74`) — when nothing is playing
    /// it is the *header* that falls back to `Color.clear`, not the shape — so
    /// the pill is visible at all times and all of it has to answer a click.
    ///
    /// This was `8` on synthetic notches, for a real reason: the middle of a
    /// working menu bar is where status items pile up once there are a few
    /// (measured on a 13" M1: they start at x≈757 while the synthetic notch
    /// spans 630…810), and claiming the full bar height there takes their
    /// clicks. The trade was made the other way on 2026-09-10: those items are
    /// already *covered* by the black shape, so what the 8 pt strip preserved
    /// was a status item you cannot see but can click, at the price of an
    /// island you can see but mostly cannot. A visible target that works beats
    /// an invisible one that does.
    var collapsedDepth: CGFloat { notchSize.height }

    /// The live media activity grows sideways beyond the physical notch. Its
    /// full visible width must remain a hover target or the new wings would
    /// look interactive while only the camera cutout actually responded.
    /// The island exactly as it is drawn, for anything about appearance rather
    /// than about opening. No padding: see `PointerWatcher.hoverRect`.
    ///
    /// `height` is the island's drawn height where it is not the notch's: a
    /// new track's peek is 50 pt tall (spec §3.5), and a rect cut for 38 would
    /// leave the 12 pt that grew below the menu bar visible and deaf. Never less
    /// than `collapsedDepth`.
    func collapsedIslandRect(for width: CGFloat, height: CGFloat? = nil) -> CGRect {
        let depth = max(collapsedDepth, height ?? collapsedDepth)
        return CGRect(
            x: notchCenterX - width / 2,
            y: screen.frame.maxY - depth,
            width: width,
            height: depth
        )
    }

    /// The drawn island for the hover lift: exactly as drawn, grown only past
    /// the top edge. Without that, a pointer thrown to the top of the display
    /// — parked on `screen.frame.maxY`, which `contains` excludes — sat under
    /// the notch and the island never noticed it; the nudge came only a few
    /// points lower. The owner, 2026-09-21: "it's not noticing when the
    /// cursor is in the edges".
    func collapsedIslandHoverRect(for width: CGFloat, height: CGFloat? = nil) -> CGRect {
        includingTopEdge(collapsedIslandRect(for: width, height: height))
    }

    /// Where an alert will be drawn once it has grown, for the pointer test
    /// made before it grows: its full depth and its shoulders, as
    /// `IslandShapeRadii` draws them, with `collapsedHoverRect`'s slop. An
    /// expanded alert reaches far below the notch and its shoulders are 20 pt,
    /// so a notch-deep strip let one grow under a pointer standing on the app
    /// below and take its click (R7 review).
    func grownAlertRect(for activity: IslandActivity, body: CGSize) -> CGRect {
        let shoulder = IslandShapeRadii.closed(for: activity).top
        return collapsedHoverRect(for: body.width + 2 * max(0, shoulder - 6), height: body.height)
    }

    func collapsedHoverRect(for width: CGFloat, height: CGFloat? = nil) -> CGRect {
        let depth = max(collapsedDepth, height ?? collapsedDepth)
        return includingTopEdge(CGRect(
            x: notchCenterX - width / 2 - 6,
            y: screen.frame.maxY - depth - (isPhysical ? 4 : 0),
            width: width + 12,
            height: depth + (isPhysical ? 4 : 0)
        ))
    }

    /// Band along the top of the display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives.
    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - NotchMetrics.warmZoneHeight,
            width: screen.frame.width,
            height: NotchMetrics.warmZoneHeight
        ))
    }

    /// The warm band plus its hysteresis margin — what a already-warm pointer
    /// has to leave before sampling drops back to the idle rate.
    ///
    /// A full rect rather than the band's lower bound alone. Testing the y
    /// coordinate by itself ignores both the width and which display the
    /// pointer is on, so a pointer that warmed up here and then moved to a
    /// display arranged above kept the 60 Hz timer running while working
    /// somewhere this panel does not exist.
    var coolZone: CGRect {
        let zone = warmZone
        return CGRect(
            x: zone.minX,
            y: zone.minY - NotchMetrics.coolMargin,
            width: zone.width,
            height: zone.height + NotchMetrics.coolMargin
        )
    }

    /// The warm band grown down by `approachMargin`: where a resting pointer
    /// is close enough to the notch that its next move is worth hearing at
    /// once (`PointerWatcher.approachZone`).
    var approachZone: CGRect {
        let zone = warmZone
        return CGRect(
            x: zone.minX,
            y: zone.minY - NotchMetrics.approachMargin,
            width: zone.width,
            height: zone.height + NotchMetrics.approachMargin
        )
    }

    /// Area that keeps the panel open while expanded, in global screen
    /// coordinates. Taken for the body actually on screen, not for the standard
    /// one: the body's width is a setting, and a rect cut for another body
    /// would call the pointer "away" while it rests on the panel's edge.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}

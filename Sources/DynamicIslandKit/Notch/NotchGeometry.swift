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

    /// Metrics of the tab rail that do not depend on the notch. `railIconHeight`
    /// is not among them — see below.
    static let railSpacing: CGFloat = 4
    /// Gap between the rail and the bottom edge of the body.
    static let bodyBottomPadding: CGFloat = 14

    /// Size of the fully expanded panel body. Held constant across every Mac:
    /// letting it follow the header made two people on the very same model
    /// see two different heights, just from different display-scaling
    /// settings — 38 pt against 32 for the same physical notch, an 11 pt
    /// spread from one slider (#27). What differs between Macs lives in
    /// `railIconHeight` instead, which is the one thing in the body actually
    /// free to give.
    /// Read once, when the geometry is built. Settings rebuilds the panel rather
    /// than nudging it, which is the same path a display change takes and the
    /// only one known to leave every rect consistent.
    let expandedSize = NotchMetrics.body(width: NotchViewModel.bodyWidth)

    /// Body for the teleprompter, the one tab that asks for more.
    ///
    /// Same width, so the panel does not change shape sideways — only the
    /// bottom edge moves, and it moves away from the notch rather than around
    /// it. The height is the smallest that fits a paragraph at a size readable
    /// without focusing: below this the tab shows the current line and the next
    /// one, which is a countdown, not a script.
    static let tallBodyHeight = NotchMetrics.teleprompterBody.height
    var tallExpandedSize: CGSize {
        CGSize(width: expandedSize.width, height: Self.tallBodyHeight)
    }
    /// Tallest body any tab can ask for. The window is cut to this once and
    /// never resized: it is transparent outside the visible panel, and what is
    /// clickable is decided separately by the active rect.
    var maxBodyHeight: CGFloat { max(expandedSize.height, Self.tallBodyHeight) }

    /// What the body has left for content on an ordinary tab, once the header
    /// and the padding beneath are taken out.
    ///
    /// The rails are held to this even on the tab that is taller, so the icons
    /// stay at the same height on every tab. Centred in the body instead, they
    /// slid down by half the difference — 96 pt — the moment the teleprompter
    /// opened, which put the icon just clicked well below the pointer that had
    /// clicked it.
    var standardContentHeight: CGFloat {
        expandedSize.height - notchSize.height - Self.bodyBottomPadding
    }

    /// Height each rail icon gets. A ceiling, not a constant: six icons at
    /// the full 24 pt plus the five 4 pt gaps between them is 164 pt, and
    /// the body only has `expandedSize.height − notchSize.height −
    /// bodyBottomPadding` left to give the rail once the header — the notch
    /// itself — and the padding beneath are taken out of the fixed 208.
    /// Rounded down rather than to the nearest point: a rail that asks for
    /// more than it is given should visibly yield, not overflow by a
    /// fraction that clips it.
    var railIconHeight: CGFloat {
        let icons = CGFloat(NotchViewModel.Tab.leftRail.count)
        let available = expandedSize.height - notchSize.height - Self.bodyBottomPadding
        let ceiling = (available - (icons - 1) * Self.railSpacing) / icons
        return min(24, ceiling).rounded(.down)
    }

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
            notchSize: CGSize(width: 180, height: max(menuBarHeight, NSStatusBar.system.thickness, 24)),
            notchCenterX: screen.frame.midX,
            isPhysical: false
        )
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
    /// A real notch is a hole: the whole of it can be claimed, because there is
    /// nothing underneath to claim it from. A synthetic one is cut out of a
    /// working menu bar — and the middle of the bar is where status items pile
    /// up once there are a few (measured on a 13" M1: they start at x≈757 while
    /// the synthetic notch spans 630…810). Claiming the full bar height there
    /// puts the panel in front of icons the user is aiming at. A strip along the
    /// very top edge is reached by throwing the pointer up — the same gesture as
    /// ever — while a pointer travelling to an icon stays below it.
    var collapsedDepth: CGFloat { isPhysical ? notchSize.height : 8 }

    /// Size of the collapsed target: the notch itself, or the strip above.
    var collapsedSize: CGSize { CGSize(width: notchSize.width, height: collapsedDepth) }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// taller than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        collapsedHoverRect(for: notchSize.width)
    }

    /// The live media activity grows sideways beyond the physical notch. Its
    /// full visible width must remain a hover target or the new wings would
    /// look interactive while only the camera cutout actually responded.
    func collapsedHoverRect(for width: CGFloat) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - width / 2 - 6,
            y: screen.frame.maxY - collapsedDepth - (isPhysical ? 4 : 0),
            width: width + 12,
            height: collapsedDepth + (isPhysical ? 4 : 0)
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

    /// Area that keeps the panel open while expanded, in global screen coordinates.
    var expandedHoverRect: CGRect { hoverRect(for: expandedSize) }

    /// Taken for the body actually on screen, not for the standard one: on the
    /// teleprompter the panel reaches 400 pt down, and a rect cut for 208 would
    /// call the pointer "away" halfway through the tab it is resting on.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}

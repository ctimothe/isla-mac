import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Screen changes, the synthetic notch, the watchdog and the rects. Stored properties live in NotchController.swift.
extension NotchController {
    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    func activeSpaceChanged() {
        geometryTrace("space changed")
        // Same repair as the wake handler: a space change with the shield
        // down while the panel still thinks it is locked means the unlock
        // transition was lost — recover rather than stay stranded.
        if !lockPresence.isLocked, viewModel?.isLockedPresentation == true {
            screenUnlocked()
        }
        // Re-assert z-order on the space just arrived at. `.canJoinAllSpaces`
        // keeps the panel present everywhere, but a transition can leave it
        // behind other windows' ordering on the new space; fronting it again
        // makes the island read as fixed to the notch the way the hardware is.
        panel?.orderFrontRegardless()
        // Entering a full-screen app is a Space change, and a moment already
        // on screen would ride into it (K-003): end it with the Space it was
        // shown on. A peek's work item is cancelled with its flag, or the flag
        // would stay raised with nothing left to lower it.
        if let vm = viewModel, momentsAreQuiet() {
            if vm.isPeeking {
                peekWork?.cancel()
                peekWork = nil
                vm.isPeeking = false
            }
            // Not the charger, which stays over a full-screen app (spec §19.4,
            // amended 2026-10-27), unless the quiet is a presentation.
            if let ambient = vm.ambient, !ambient.isChargerMoment || momentsAreQuiet(presentingOnly: true) {
                clearAmbient()
            }
            // An offer still unanswered goes too, and comes back once the
            // quiet ends; an install under way stays, it is the person's.
            if let offer = vm.updateOffer, updateStage(for: offer).isTimed { clearUpdateOffer() }
        }
        // The pop-up is an answer to a key press and rides no Space into a new
        // one: it ends with the Space it was shown on — and an alert that was
        // waiting behind it gets the island, as when the pop-up folds. A
        // confirmation is an answer too, and goes the same way.
        clearHUD()
        clearConfirmation()
        promoteWaitingAlert()
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    func screenParametersChanged() {
        // No screens at all, for the moment. Nothing to anchor to and nothing
        // to draw; the next notification arrives with the new arrangement.
        guard let fresh = NotchGeometry.current() else {
            geometryTrace("params: no screen")
            return
        }
        geometryTrace("params: fresh \(Self.describe(fresh)) current \(viewModel.map { Self.describe($0.geometry) } ?? "nil")")
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            geometryTrace("params: rebuilding (locked=\(viewModel?.isLockedPresentation == true ? 1 : 0))")
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        //
        // Except while the shield is up, where the panel is deliberately the
        // size of the whole screen so the card can sit at its centre. These
        // notifications fire for plenty of reasons that change nothing — the
        // locked display sleeping and rewaking is one — and re-applying the
        // notch frame to a locked panel shrank it back to 700×444, stranding
        // the card off-centre and unclickable until unlock.
        if let screen = viewModel?.geometry.screen { lockCard.reposition(on: screen) }
        panel?.setFrame(fresh.windowFrame, display: false)
        recutPointerRects()
    }

    /// Same display, same notch — but not necessarily the same neighbours.
    ///
    /// A rect that reaches the top edge grows past it only where no display
    /// sits directly above (`NotchGeometry.includingTopEdge`), and docking or
    /// undocking one there changes that without moving this display at all.
    /// Cut only in `build` and on the panel's own changes, the rects kept
    /// reaching two points into a display just docked above — its bottom edge
    /// lit the island and warmed the sampler — or stopped short of an edge
    /// that had just become one, so a click thrown at the top of the screen
    /// fell through, until the next track change or open re-cut them.
    private func recutPointerRects() {
        guard let vm = viewModel else { return }
        pointer.warmZone = vm.geometry.warmZone
        pointer.coolZone = vm.geometry.coolZone
        pointer.approachZone = vm.geometry.approachZone
        pointer.closeRect = vm.geometry.hoverRect(for: vm.openBodySize)
        // A display change moves the geometry without animating the body: no
        // spring to wait for, so a shrink applies at once.
        if vm.isOpen { refreshOpenRects(animated: false) } else { refreshCollapsedRects() }
    }

    /// A synthetic notch found at launch is checked again shortly after.
    ///
    /// `NotchGeometry` remembers a display's cutout and refuses to forget it on
    /// a glitched reading, but the memory is empty on the first read — and the
    /// first read happens at login, which is exactly when a Mac is still
    /// settling its displays. A launch that lands in that window would draw the
    /// synthetic pill for the rest of the session, since nothing else asks
    /// again. Two later looks cost nothing and end that.
    ///
    /// Asked at the end of every `build()`, not only at launch: a display
    /// reconfiguration or a wake rebuilds the panel while the built-in display
    /// is just as unsettled, and a synthetic pill drawn then stayed for the
    /// session (F-047). The generation stamp bounds that — each build's looks
    /// belong to it alone, so a rebuild storm leaves one pair of live looks.
    nonisolated static func syntheticRecheckDelays(
        isPhysical: Bool, generation: Int, current: Int
    ) -> [TimeInterval] {
        guard !isPhysical, generation == current else { return [] }
        return [1.5, 5.0]
    }

    func verifySyntheticNotch() {
        let generation = buildGeneration
        let delays = Self.syntheticRecheckDelays(
            isPhysical: viewModel?.geometry.isPhysical ?? true,
            generation: generation,
            current: buildGeneration
        )
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.buildGeneration == generation,
                          self.viewModel?.geometry.isPhysical == false else { return }
                    guard let fresh = NotchGeometry.current(), fresh.isPhysical else { return }
                    self.geometryTrace("late notch found, rebuilding")
                    self.rebuild()
                }
            }
        }
    }

    /// A transaction that refuses to animate whatever is written inside it.
    static var cut: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// Verification-only geometry trail, behind DI_GEOM=1: the panel drifting
    /// out of place is a state, not an event, so the watchdog samples as well
    /// as narrating each notification that could have caused it.
    func geometryTrace(_ message: @autoclosure () -> String) {
        guard DebugTrail.geometry else { return }
        DebugTrail.note("GEOM \(message())")
    }

    static func describe(_ geometry: NotchGeometry) -> String {
        String(
            format: "screen=%.0fx%.0f@%.0f,%.0f notch=%.0fx%.0f cx=%.0f physical=%d scale=%.1f",
            geometry.screen.frame.width, geometry.screen.frame.height,
            geometry.screen.frame.origin.x, geometry.screen.frame.origin.y,
            geometry.notchSize.width, geometry.notchSize.height,
            geometry.notchCenterX, geometry.isPhysical ? 1 : 0,
            geometry.screen.backingScaleFactor
        )
    }

    /// Watches where the panel actually is against where it belongs — and puts
    /// it back when the two disagree.
    ///
    /// Not only a diagnostic. A panel can be moved or resized by things this
    /// app never hears about, and the failure it produces — the island and the
    /// card drawn small and off to one side — is invisible from the inside and
    /// stands until some later notification happens to correct it. Two seconds
    /// is far below noticing, and re-applying a frame that is already right
    /// costs nothing because it is skipped.
    func startGeometryWatchdog() {
        guard geometryWatchdog == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, let vm = self.viewModel else { return }
                // One frame for the panel's whole life now: the card is a
                // separate window, so nothing about a lock changes this one.
                let want = vm.geometry.windowFrame
                let have = panel.frame
                let agrees = abs(want.origin.x - have.origin.x) < 1 && abs(want.origin.y - have.origin.y) < 1
                    && abs(want.width - have.width) < 1 && abs(want.height - have.height) < 1
                // The window's frame is only half of it. The content view and
                // the SwiftUI view inside it carry their own sizes, and a card
                // drawn at half scale in a correctly-sized window is what it
                // looks like when those disagree — the window is right and the
                // layout is describing a different display.
                let content = panel.contentView
                let hosted = (content as? NotchRootView)?.islandHosting ?? content?.subviews.first
                let contentFits = content.map {
                    abs($0.bounds.width - have.width) < 1 && abs($0.bounds.height - have.height) < 1
                } ?? true
                let hostedFits = hosted.map {
                    abs($0.frame.width - have.width) < 1 && abs($0.frame.height - have.height) < 1
                } ?? true
                if DebugTrail.geometry {
                    DebugTrail.note(String(
                        format: "GEOM watch panel=%.0fx%.0f@%.0f,%.0f want=%.0fx%.0f@%.0f,%.0f %@ content=%.0fx%.0f hosted=%.0fx%.0f%@%@ locked=%d card=%d %@",
                        have.width, have.height, have.origin.x, have.origin.y,
                        want.width, want.height, want.origin.x, want.origin.y,
                        agrees ? "ok" : "DRIFTED",
                        content?.bounds.width ?? -1, content?.bounds.height ?? -1,
                        hosted?.frame.width ?? -1, hosted?.frame.height ?? -1,
                        contentFits ? "" : " CONTENT-MISMATCH",
                        hostedFits ? "" : " HOSTED-MISMATCH",
                        vm.isLockedPresentation ? 1 : 0,
                        self.lockCard.isPresenting ? 1 : 0,
                        Self.describe(vm.geometry)
                    ))
                }
                guard !agrees || !contentFits || !hostedFits else { return }
                if !agrees { panel.setFrame(want, display: true) }
                // A resize the window server deferred leaves SwiftUI proposing
                // the old size — which is the shrunken, off-centre card itself.
                // Both layers are put back, not only the outer one.
                content?.frame = CGRect(origin: .zero, size: want.size)
                hosted?.frame = CGRect(origin: .zero, size: want.size)
                content?.layoutSubtreeIfNeeded()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        geometryWatchdog = timer
    }

    func stopGeometryWatchdog() {
        geometryWatchdog?.invalidate()
        geometryWatchdog = nil
    }

    /// The height the open rects are cut for: growing is immediate, so the
    /// pointer never falls through a region the animation has not covered yet,
    /// but shrinking waits for the body to stop. Collapse springs the body from
    /// 400 down to 208 over `Theme.expandSettle`, and the rects used to drop to
    /// 208 on the first frame: for that long the still-drawn lower part of the
    /// panel let every click through to the app beneath it, and a pointer
    /// resting there stood outside the close rect and folded the panel shut
    /// (review 2026-10-15). `bodySettled` is true on the pass scheduled for the
    /// end of the spring.
    nonisolated static func openRectHeight(applied: CGFloat?, target: CGFloat, bodySettled: Bool) -> CGFloat {
        guard let applied, target < applied, !bodySettled else { return target }
        return applied
    }

    /// The same for both sides: the surfaces differ in width as well as height
    /// (spec §19.6–§19.8), and the stage turning into the player narrows the
    /// shape by two hundred points on the island's spring. Each side grows at
    /// once and shrinks when the body has stopped.
    nonisolated static func openRectSize(applied: CGSize?, target: CGSize, bodySettled: Bool) -> CGSize {
        CGSize(
            width: openRectHeight(applied: applied?.width, target: target.width, bodySettled: bodySettled),
            height: openRectHeight(applied: applied?.height, target: target.height, bodySettled: bodySettled)
        )
    }

    /// The closed island as drawn now, in screen coordinates: every point a
    /// click lands on — the padded strip, the shoulders `closedTopRadius`
    /// wide, the Shelf's bubble. What `PointerWatcher.islandRect` reads.
    func collapsedIslandScreenRect() -> CGRect {
        guard let vm = viewModel else { return .zero }
        let width = vm.bodySize.width, height = vm.bodySize.height
        let bubble = vm.bubble.map {
            vm.geometry.bubbleScreenRect(islandWidth: width, height: height, bubbleWidth: IslandBubbleLayout.width(for: $0))
        } ?? .zero
        return Self.collapsedIslandRect(
            geometry: vm.geometry,
            body: CGSize(width: width, height: max(vm.geometry.collapsedDepth, height)),
            shoulder: vm.closedTopRadius,
            bubble: bubble
        )
    }

    /// The pure half of `collapsedIslandScreenRect()`: the hover strip, the
    /// clickable shape with its shoulders, and the bubble when there is one.
    nonisolated static func collapsedIslandRect(
        geometry: NotchGeometry, body: CGSize, shoulder: CGFloat, bubble: CGRect
    ) -> CGRect {
        let strip = geometry.collapsedHoverRect(for: body.width, height: body.height)
        let shape = geometry.contentScreenRect(for: body).insetBy(dx: -shoulder, dy: 0)
        let island = strip.union(shape)
        return bubble.isEmpty ? island : island.union(bubble)
    }

    /// Re-cuts both rects for the body currently on screen.
    func refreshOpenRects(
        bodySettled: Bool = false, animated: Bool = true,
        reduceMotion: Bool? = nil
    ) {
        guard let vm = viewModel, vm.isOpen else { return }
        rectShrinkWork?.cancel()
        rectShrinkWork = nil
        let target = vm.openBodySize
        let hold = Self.shrinkHold(
            reduceMotion: reduceMotion ?? SystemAppearance.shared.reduceMotion, animated: animated
        )
        let size = Self.openRectSize(
            applied: appliedOpenSize, target: target, bodySettled: bodySettled || hold == 0
        )
        if size.height > target.height || size.width > target.width {
            // Still shrinking: look again when the spring has settled. A newer
            // refresh cancels this one and decides afresh.
            let work = DispatchWorkItem { [weak self] in
                self?.rectShrinkWork = nil
                self?.refreshOpenRects(bodySettled: true)
            }
            rectShrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
        applyActiveRect(open: true, body: size)
        pointer.closeRect = vm.geometry.hoverRect(for: size)
    }

    func refreshCollapsedRects() {
        guard let vm = viewModel, !vm.isOpen, !vm.isDropTargeted else { return }
        // A panel still folding keeps its clicks until the fold is done; the
        // close's own cut, already scheduled for then, reads whatever is
        // current when it lands. Cut here, an alert promoted the moment the
        // panel began to close let clicks on the visibly folding panel through
        // to the app behind it (R7 review).
        if let pending = closeActiveRectWork, !pending.isCancelled { return }
        // The locked panel's rect is the card's, and it is cut against a
        // screen-sized window — see `sneakPeek`. Re-cut it for the card, not
        // for the collapsed shell.
        guard !vm.isLockedPresentation else {
            applyLockedActiveRect()
            return
        }
        applyActiveRect(open: false)
    }


    func applyActiveRect(open: Bool, body: CGSize? = nil) {
        guard let vm = viewModel, let rootView else { return }
        // Any cut that is not a refresh's own outdates the shrink one is waiting
        // to make; a refresh passes `body` and has scheduled its own.
        if body == nil {
            rectShrinkWork?.cancel()
            rectShrinkWork = nil
        }
        // Collapsed, the panel claims the island as drawn — the full notch
        // height on every display, synthetic or not. It used to stop 8 pt down
        // on a synthetic notch so that menu-bar status items underneath kept
        // their clicks; since `NotchShape` fills black unconditionally there,
        // that left most of a permanently visible island dead, and the trade
        // was reversed on 2026-09-10. The open size is the current tab's, not a
        // constant: the teleprompter is taller, and a rect cut for 208 would
        // leave the bottom half of it visible but untouchable.
        let size: CGSize
        if open {
            size = body ?? vm.openBodySize
            appliedOpenSize = size
            // The way back in. `openRect` was only ever cut for the collapsed
            // strip, so once the pointer had been counted as away from an open
            // panel, moving back onto its 620×208 body registered as nothing
            // and only a trip to the notch could reopen it.
            pointer.openRect = vm.geometry.hoverRect(for: size)
        } else {
            appliedOpenSize = nil
            // The full drawn depth, and the full width of the visible compact
            // activity — the pill widens with what is playing, and every point
            // of what is drawn has to open the panel.
            //
            // And the full drawn height: an alert hangs under the notch — a
            // new track as the pop-up does (spec §3.5, amended 2026-11-15) —
            // and `collapsedDepth` alone is the notch's 38. The rects are
            // re-cut on `isPeeking` in both directions, so they cover what
            // grew for the hold and shrink back with the fold.
            let drawnDepth = max(vm.geometry.collapsedDepth, vm.bodySize.height)
            size = CGSize(width: vm.bodySize.width, height: drawnDepth)
            pointer.openRect = vm.geometry.collapsedHoverRect(for: vm.bodySize.width, height: drawnDepth)
        }
        // Follows the island, which changes width with what is playing and
        // with each alert it shows. Left at the width it was built with, the
        // lift would stop short of the artwork the moment a track started.
        pointer.hoverRect = vm.geometry.collapsedIslandHoverRect(
            for: vm.bodySize.width, height: open ? nil : vm.bodySize.height
        )
        // The shape is drawn `topRadius` wider than the body on each side —
        // that slack is where the concave shoulders live — so the clickable
        // rect is grown to match it. Every point of the compact island opens
        // the panel: the artwork side, the cutout between, the equalizer side,
        // and the shoulders at either end.
        //
        // It follows `bodySize.width`, so it is correct at any width the panel
        // is set to and re-cut whenever that changes.
        //
        // The cost, stated: a status item sitting within `topRadius` of the
        // notch loses that sliver of itself to the panel. Collapsed, this used
        // to stay flush with the body to protect exactly that — but a compact
        // island with dead ends is the worse trade, because the dead ends are
        // invisible and the menu bar's are not.
        updateShelfZone(open: open, size: size)
        // The shoulders of what is drawn: an expanded alert's are wider than a
        // compact activity's (`IslandShapeRadii`).
        let slack = open ? vm.openTopRadius : vm.closedTopRadius
        let rect = vm.geometry.contentRect(for: size).insetBy(dx: -slack, dy: 0)
        rootView.activeRect = NotchRootView.reachingTopEdge(rect, windowHeight: vm.geometry.windowSize.height)
        geometryTrace(String(format: "activeRect open=%d w=%.0f h=%.0f", open ? 1 : 0, rect.width, rect.height))
        // Drags are aimed by hand and land wide, so the target is the visible
        // island generously grown — but nothing like the whole 700×444 window,
        // which is what used to accept a drag merely crossing the top of the
        // screen and switch the panel to the shelf for it.
        rootView.dropRect = rect.insetBy(dx: -24, dy: -24)
        // Widened to match, or the window would ignore mouse events over the
        // very shoulders the rect above just made clickable.
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: -slack, dy: 0)
        // The Shelf's bubble beside Music, its own region (spec §19.7). Re-cut
        // with the island: everything that brings it or takes it away — a
        // track, a pause settling, an alert, the Shelf's first and last file,
        // opening, the lock — already re-cuts these rects.
        if !open, let bubble = vm.bubble {
            let width = vm.bodySize.width, height = vm.bodySize.height
            let bubbleWidth = IslandBubbleLayout.width(for: bubble)
            rootView.bubbleRect = NotchRootView.reachingTopEdge(
                vm.geometry.bubbleRect(islandWidth: width, height: height, bubbleWidth: bubbleWidth),
                windowHeight: vm.geometry.windowSize.height
            )
            pointer.bubbleRect = vm.geometry.bubbleScreenRect(islandWidth: width, height: height, bubbleWidth: bubbleWidth)
        } else {
            rootView.bubbleRect = .zero
            pointer.bubbleRect = .zero
        }
    }
}

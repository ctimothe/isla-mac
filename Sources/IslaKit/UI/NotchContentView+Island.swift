import SwiftUI

/// The island's shell and the locked pill. Stored properties live in NotchContentView.swift.
extension NotchContentView {
    /// The pill over the shield: the same pill, and the same fold.
    ///
    /// It was mounted only while something played, and that made the fold a
    /// cut. This branch refuses every animation that reaches it from outside —
    /// the lock is a cut, see `body` — and an `if` around the whole pill is
    /// decided out there, so a pause removed the island in a single frame:
    /// filmed on 2026-09-21, the one motion on the lock screen with no motion
    /// in it. The pill now stays mounted for the whole lock and answers its own
    /// change with its own curve, declared beneath the refusal, so the wings
    /// contract into the cutout and the cover dissolves ahead of the edge
    /// exactly as they do unlocked. The lock itself still arrives as a cut:
    /// the controller flips it with animations disabled, which an `.animation`
    /// in here cannot re-enable.
    var lockedPill: some View {
        // The wings are the island's own and the banner or the card is the
        // song's: while it is up the island rests in the notch, wherever the
        // song is playing (spec §3.7, owner decision 1; `LockedIsland`).
        // An alert — the volume pop-up, the charger — takes the wings for its
        // hold and folds back (amended 2026-10-26), whatever holds the song.
        let alert = vm.lockedAlert
        let shown = vm.lockedIslandShowsWings || alert != nil
        let notch = vm.geometry.notchSize
        // The notch the banner or the card leaves alone still answers: a hover
        // wakes it as it wakes any resting notch, and a click shakes it. Only over
        // a real cutout — a display without one draws no resting island to wake.
        let answers = vm.lockSurfacePresentsSong && vm.geometry.isPhysical
        let awake = !shown && answers && vm.isHovering
        let out = shown || awake
        // The wings are as tall as the unlocked pill's outline, so the lock's
        // cut does not also step the shape by the half-stroke it drops.
        let shape = shown
            ? Self.clearingCutout(
                CGSize(width: size.width + 2 * Theme.collapsedTopRadius, height: notch.height),
                notchHeight: notch.height, isPhysical: vm.geometry.isPhysical
            )
            : (awake
                ? Self.awakeShape(notch: notch, shoulder: Theme.collapsedTopRadius)
                : Self.restingShape(notch: notch))
        return ZStack(alignment: .top) {
            NotchShape(
                topRadius: out ? Theme.collapsedTopRadius : 0,
                bottomRadius: out ? Theme.collapsedBottomRadius : Theme.restingNotchBottomRadius
            )
            .fill(out && vm.isHovering ? Theme.islandHover : Color.black)
            .frame(width: shape.width, height: shape.height)
            // A display with no cutout has nowhere to fold into, so there the
            // shape itself goes; over a real notch it ends inside the hole,
            // where there is no pixel left to hide.
            .opacity(shown || vm.geometry.isPhysical ? 1 : 0)
            // No namespace over the shield, on purpose. This pill and the
            // unlocked one are two branches of `body` that swap in a single
            // transaction, so sharing an identity would hand the lock a
            // travelling cover to interpolate — and the lock is a cut.
            if let alert {
                lockedAlertContent(alert)
                    .frame(width: size.width, alignment: .center)
                    .clipped()
                    .transition(Theme.compactArrival(reduceMotion: reduceMotion))
            } else if shown {
                compactMediaHeader(morph: nil)
                    // Held inside the wings the way the unlocked shell holds it,
                    // so the last blurred trace of the cover can never be drawn on
                    // the wallpaper beside a shape that has already moved in.
                    .frame(width: size.width, alignment: .center)
                    .clipped()
                    // The refusal under Reduce Motion: the content dips, the black
                    // shape above stays put (see `RefusalShake`).
                    .refusalContentDim()
            } else {
                // The wings are not drawn but the island still has the notch's
                // height and the width the pointer is answered over: the row the
                // click target and VoiceOver's frame are cut from, as the header
                // was when nothing played.
                Color.clear
                    .frame(width: answers ? vm.lockedIslandSize.width : size.width, height: notch.height)
            }
        }
        // Isla over the shield too, folded or not: pressed, it gives the
        // refusal a click gets. With nothing playing this island used to be
        // absent to VoiceOver on the lock screen as well (H-001).
        .modifier(islandAccessibility(open: false))
        // The click target is the pill, cut before the row is widened to the
        // window — see the same placement in `shell` for why it matters to
        // VoiceOver. The panel's active rect is this same width, so no click
        // the pointer could deliver lands anywhere different.
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .top)
        // The same `#1C1C1E` under the pointer as unlocked, on the pill's own
        // fill above — only on a pill that is there.
        .animation(Theme.contentAnimation, value: vm.isHovering)
        // The resting notch waking under the pointer, and going back, on the
        // same bump it has anywhere: a hover over the lock screen is the same
        // question the island answers on the desktop.
        .animation(Theme.hoverNudge(reduceMotion: reduceMotion), value: awake)
        // The edge says the island is there; the shake says it is not opening
        // here. Two different answers to two different gestures, rather than
        // one shake for both.
        .onTapGesture { vm.onIslandClick?() }
        // Folded, the shape sits one point inside the cutout, and an 11 pt
        // swing would carry ten of them out onto the wallpaper beside it. There
        // is no pill to shake, so nothing shakes. Hovered — and a click needs
        // a pointer on it — the notch has grown past the cutout and shakes with
        // it (`Lock-Refusal`).
        .refusalShake(trigger: vm.lockedHoverNudges, amplitude: out ? RefusalShake.standardAmplitude : 0)
        // Folded, there is nothing here to answer: the notch is only a notch —
        // unless the banner or the card holds the song, when the pointer's
        // hover and click are the two answers the board asks for.
        .allowsHitTesting(shown || answers)
        .animation(Theme.pill(reduceMotion: reduceMotion), value: compactActivity)
        // The alerts' own curves, declared beneath the lock's refusal like the
        // fold above: the pop-up's quick one in and out, the charger's pill.
        .animation(Theme.hud(reduceMotion: reduceMotion), value: vm.hudShown)
        .animation(Theme.pill(reduceMotion: reduceMotion), value: vm.ambient)
    }

    /// What an alert over the shield draws in the wings: the pop-up's compact
    /// form, or the charger exactly as the shut island draws it.
    @ViewBuilder
    private func lockedAlertContent(_ alert: IslandActivity) -> some View {
        switch alert {
        case .hud:
            LockedHUDContent(live: vm.hudLive, size: size)
        case .ambient(let ambient):
            ambientHeader(ambient)
        default:
            EmptyView()
        }
    }

    /// The part of the shell gesture that acts: the drawn collapsed island,
    /// shoulders included, in the coordinates `DragGesture` reports.
    ///
    /// Lifted out of the release rather than copied into the press, so what
    /// lights up under a press and what commits when it lifts cannot come to
    /// disagree about where the island is.
    private var islandBounds: CGRect {
        // Asked of the geometry rather than built here, so this and
        // `NotchController.applyActiveRect` cannot describe the island
        // differently — they did, and this one was the wrong one. It read
        // `origin: .zero` while the gesture below reports its clicks in the
        // whole window's space and the island is centred in it, so the region
        // that actually opened the panel was the island's left edge and nothing
        // else. See `NotchGeometry.compactGestureRect`.
        vm.geometry.compactGestureRect(for: size, topRadius: topRadius)
    }

    var shell: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            if let outline {
                // The fill, the shadow, the mask below and the line over it are
                // layers (`IslandOutlineHost`): this says what they are and on
                // which transaction they change, and holds no size and takes
                // no place in the layout.
                IslandOutlineBridge(host: outline, state: outlineState)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                NotchShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
                .fill(shapeFill)
                .frame(width: drawnShapeSize.width, height: drawnShapeSize.height)
                // A surface or an alert separates from a busy window under it; a
                // compact activity sits on the menu bar's strip and casts nothing
                // (spec §19.2). Faded rather than switched, so it grows with the
                // shape instead of arriving after it.
                .shadow(
                    color: .black.opacity(
                        IslandStroke.castsShadow(height: shapeSize.height) ? Theme.islandShadowOpacity : 0
                    ),
                    radius: Theme.islandShadowRadius
                )
            }

            // The shape is the only black. A second black layer used to sit
            // over the wings, faded out on its own 0.12 s while the shape
            // contracted — and a removed view keeps the frame it had, so for
            // the first tenth of every fold the pill's full outline stayed on
            // screen, dimming, over a shape already moving in. A fold that
            // begins as a fade is not a fold. Both layers were plain black by
            // then, so the one that could not move is the one that went.

            VStack(spacing: 0) {
                header
                if bodyShown {
                    // The body arrives after the panel, and leaves before it.
                    //
                    // This was a plain `.transition(.opacity)`, which carries no
                    // animation of its own and so resolved against whatever was
                    // in flight — the open spring on the `.animation(...,
                    // value: isOpen)` below. Content and container therefore ran
                    // on one curve, and the container is a 444pt panel growing
                    // out of a 32pt notch: at the moment the body was already
                    // half visible the panel was still half its height, and the
                    // `.clipped()` two lines down cut the rail and the pane
                    // through the middle of their glyphs. Text fading up through
                    // a horizontal cut is not a reveal, it is a rendering
                    // artefact that happens to be animated.
                    //
                    // `Theme.paneIn`/`paneOut` is the pair this file already
                    // uses for tab swaps and the rule is `Theme`'s own: out fast
                    // (0.10s, on an ease-out), in slower and behind a small
                    // delay, so the two states are never both half-present for
                    // long. Applied here it means the panel has height before
                    // the body has alpha, and on close the body is mostly gone
                    // before the shape — held back `Theme.closeShapeDelay` —
                    // has eaten the bottom padding and reached it (H-012).
                    //
                    // Opacity only — deliberately not the `.scale` the pane
                    // switch adds. The far end of the artwork morph
                    // (`MorphID.artwork`, drawn inside `MediaPane`) is a
                    // descendant of this view, and a scale on an ancestor is a
                    // geometry change applied on top of the one
                    // `matchedGeometryEffect` is interpolating: the cover would
                    // travel to a frame that was itself being resized under it.
                    // Note also that the transition lives here, on the
                    // container, and *not* on either matched view — a view
                    // carrying a matched geometry effect must never also carry
                    // an opacity transition, or it fades while it flies.
                    content
                        .transition(.asymmetric(
                            insertion: .opacity.animation(Theme.paneIn),
                            removal: .opacity.animation(Theme.paneOut)
                        ))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            // Nothing is ever drawn outside the island (owner, 2026-10-18: no
            // content may go over the island's edges, "that's a hard rule").
            // The clip used to be square at rest and rounded only
            // while two pages travelled, so every other motion could leave
            // content outside the outline: a pane removed on a surface change
            // keeps the frame it had while the outline springs to the new
            // size, and a close folds the corners in over a body still fading
            // — both drew past the rounded bottom corners onto the wallpaper.
            // Masked by the outline itself, built from the same radii and the
            // same frame as the black shape, the content follows the shape
            // through every spring and cannot leave it in any frame.
            //
            // The rectangle first: a mask from a path is applied to what
            // SwiftUI draws, and a square clip is what AppKit-backed views —
            // the text editor, the scroll views, the pop-up menus — are
            // guaranteed to honour as well, so the rule does not depend on how
            // a control happens to be drawn.
            .clipped()
            // With the outline on Core Animation its layer mask cuts the hosting
            // view's whole layer instead, on the render server's clock, so this
            // cut is not made twice (and not on the main thread).
            .modifier(OutlineMask(
                active: outline == nil, topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius, size: drawnShapeSize
            ))

            // Over the black *and over the content*, centred on its edge, so
            // half the line lies outside the shape and half inside. It sat
            // under the content until 2026-10-18, and Translate's input card
            // swiped past the last page slid over the inner half of the line:
            // the island's own border looked overlapped by what it holds
            // (owner's review). The border is the edge of the island; nothing
            // inside passes over it. Always mounted and faded, never inserted,
            // so it folds and unfolds with the shape instead of arriving after
            // it, and built from the same radii and the same frame, so it
            // follows the outline through every spring.
            if outline == nil {
                IslandStrokeShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
                    .stroke(strokeColor, lineWidth: Theme.islandStrokeWidth)
                    .frame(width: drawnShapeSize.width, height: drawnShapeSize.height)
                    .opacity(strokeShown ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        // A click anywhere on the collapsed island opens it. The equalizer
        // wing keeps its own tap for play/pause — a child gesture wins, so
        // pausing still costs one click and does not open anything, and the open
        // panel's header strip closes the panel by winning the same way.
        //
        // Cut to the island, shoulders included, and *then* widened to the
        // window — not the other way round. SwiftUI hands a content shape to
        // the accessibility element beneath it when that element is the only
        // one there, and on a shut island the Isla button is the only one: cut
        // after the window-filling frame, the button's frame was the whole
        // 700-point window instead of the island (H-001). This rect is
        // `compactGestureRect` and the panel's active rect exactly, so no
        // click the pointer can deliver lands anywhere different.
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Highlight on press, commit on release — the order Apple states for a
        // tap. Waiting for the click to show anything makes the island feel
        // dead for the length of the press, which is the one moment the user is
        // asking it a question.
        .gesture(
            DragGesture(minimumDistance: 0)
                // Lit for exactly the region the release will act on, and for no
                // other: this shape is the whole window, so a press that landed
                // beside the island — or slid off it on the way to being let go
                // — used to light the island up for a click it was always going
                // to throw away.
                .onChanged { value in
                    let pressed = !isOpen && islandBounds.contains(value.location)
                    // Written only when it changes. This fires on every pointer
                    // sample for as long as the button is down, and an open
                    // panel with a scrub slider or a scrolling lyric under the
                    // pointer must not be re-rendered by a gesture that has
                    // nothing to say about it.
                    if isPressed != pressed { isPressed = pressed }
                }
                .onEnded { value in
                    isPressed = false
                    guard !isOpen else { return }
                    // Only if the pointer is still on the island. Dragging away
                    // and letting go cancels, which is what every button on the
                    // platform does.
                    let inside = islandBounds.contains(value.location)
                    // Diagnostic, behind DI_GEOM=1: pairs with the CLICK line in
                    // `NotchRootView.hitTest`, so a dead spot reads as
                    // hit-but-cancelled here versus never-delivered there.
                    if DebugTrail.geometry {
                        DebugTrail.note(String(
                            format: "GESTURE loc=(%.1f,%.1f) island=(%.1f,%.1f,%.1f,%.1f) inside=%d",
                            value.location.x, value.location.y,
                            islandBounds.minX, islandBounds.minY,
                            islandBounds.width, islandBounds.height,
                            inside ? 1 : 0
                        ))
                    }
                    if inside { vm.onIslandClick?() }
                }
        )
        // Open and close by direction, as the pill's fold and unfold are: the
        // close waits `Theme.closeShapeDelay` so the body is gone before the
        // clip comes for it (H-012). Must agree with the controller's own
        // `withAnimation`, or the two transactions disagree about when the
        // shape starts.
        .animation(isOpen ? Theme.open(reduceMotion: reduceMotion) : Theme.close(reduceMotion: reduceMotion), value: isOpen)
        // The body a pass after the outline (`bodyStaged`). Shut, it is
        // unstaged at once, so the next open stages again; opened, it is let
        // in on the next pass if the panel is still open then.
        .onChange(of: isOpen) { _, open in
            guard open else { bodyStaged = false; return }
            DispatchQueue.main.async {
                guard vm.isOpen || vm.isDropTargeted else { return }
                bodyStaged = true
            }
        }
        // The pointer arriving. Over a playing island that is a brightening on
        // a quick ease; over one resting hidden in the notch it is the island
        // growing out of the cutout with a single small bump — see
        // `Theme.hoverNudge`. One curve for both: the brightening has no
        // geometry to overshoot, so the bump only ever shows where it means
        // something.
        .animation(Theme.hoverNudge(reduceMotion: reduceMotion), value: vm.isHovering)
        // A press deepens nothing now — it is the same `#1C1C1E` as the hover —
        // but it still arrives on a quick ease rather than a cut.
        .animation(Theme.contentAnimation, value: isPressed)
        // Out of the notch and back into it, and from one activity to
        // another, each on the spring the iPhone's island uses for that
        // change (spec §19.3, amended 2026-11-14; `IslandMotion`): a compact
        // activity arriving overshoots, an alert opening barely does, a fold
        // back is nearly damped and going home is not sprung past at all. The
        // keys are the ones these changes always rode: the song's pill, the
        // charger and headphones, the confirmation, and the update
        // alert — keyed to its version, not to the offer, since the
        // installer's progress redraws inside it and moves no edge.
        .modifier(IslandMorph(
            presentation: IslandMotion.presentation(
                of: vm.activity, hasBubble: vm.bubble != nil, liveControls: vm.showsLiveControls
            ),
            keys: MorphKeys(
                compact: compactActivity, ambient: vm.ambient,
                confirmation: vm.confirmation, update: vm.updateOffer?.version,
                live: vm.liveActivities.map(\.kind), liveControls: vm.showsLiveControls,
                bubble: vm.bubble.map { IslandMotion.presentation(of: $0) }
            ),
            reduceMotion: reduceMotion
        ))
        // The pop-up widens and folds on its own quick, critically damped
        // spring (`Theme.hudSpring`, spec §19.3 amended 2026-10-18). Keyed to
        // whether it is up, not to its level: a press only moves the bar,
        // which has a curve of its own.
        .animation(Theme.hud(reduceMotion: reduceMotion), value: vm.hud != nil)
        // A new track is the pop-up with the song in it, and rides the same
        // spring in and out (§3.5, amended 2026-11-15), not the morph.
        .animation(Theme.hud(reduceMotion: reduceMotion), value: vm.isPeeking)
        // The Shelf as the live activity coming and going, and its count
        // changing (spec §19.4) — a file kept with the panel shut. Keyed to
        // the live count, not the Shelf's: a collected file's moment begins
        // and ends with no change to the count — at the Shelf's limit a
        // capture adds one card and evicts one — and the island jumped in and
        // out of the notch without its spring (R7 review).
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.liveShelfCount)
        // The shoulders follow the surface: 24 for the Shelf's, 34 for the rest.
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.openTopRadius)
        // The body growing or folding (spec §6): its height, its bottom radius
        // and — through the same value — the stroke that follows them, on the
        // outline's spring (spec §19.3), or the 0.24 crossfade under Reduce
        // Motion. Keyed to the
        // *open* body's height, which opening and closing do not change, so this
        // never answers the open spring's own change of size.
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.openBodySize.height)
        // The welcome ending is a pane change like any other, and it arrives
        // from a `Button` — which animates nothing by itself, so without this
        // the crossfade above would be a cut.
        .animation(Theme.paneAnimation, value: vm.isShowingWelcome)
        // A surface change, outermost, so that when it also changes the
        // body's size the outline's spring above wins for the shape. It used
        // to sit inside them, and the innermost `.animation` a change reaches
        // is the one its transaction keeps: the gear opening Settings grew
        // the island from the player's size to Settings' on this 0.18 s
        // ease-out while every other change of size rode the spring, the one
        // motion in the island that moved like something else (owner's
        // review, 2026-10-18: treat the island as one thing). What
        // the change alone moves — the header's title, the dots — still fades
        // on it; the panes carry their own curves (`Theme.swapIn`/`swapOut`).
        .animation(Theme.paneAnimation, value: vm.presented)
    }
}

import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// The pages on their way between two (spec §19.16): watched here, where
    /// the outline and the pages are drawn from it, and nowhere else.
    @ObservedObject private var travel: PageTravel
    /// Reduce Motion and Increase Contrast from the app's one source rather than
    /// from SwiftUI's environment. The environment answers Reduce Motion on
    /// macOS — it is the only one of the three display settings it carries —
    /// but the panel is drawn from AppKit as much as from SwiftUI, and two
    /// readings of one setting is how half a transition ends up honouring it
    /// and half does not. Observed once here, at the root: `Theme`'s colours
    /// and `LyricRow`'s falloff read `SystemAppearance.shared` directly, which
    /// on its own would not invalidate anything, but every pane is a
    /// descendant of this view, so a change re-renders this body and the whole
    /// tree under it — rail, panes, and lyric lines alike.
    @ObservedObject private var appearance = SystemAppearance.shared
    private var reduceMotion: Bool { appearance.reduceMotion }
    /// The update badge on Tools' Settings, and the shortcuts Tools' cards
    /// name: both follow their sources while the panel is up.
    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    init(vm: NotchViewModel) {
        _vm = ObservedObject(wrappedValue: vm)
        _travel = ObservedObject(wrappedValue: vm.pageTravel)
    }

    /// Translate's History is offered only while Keep History is on (spec
    /// §11): read from the translator's own defaults when the header draws,
    /// which every surface change does.
    private var translateKeepsHistory: Bool {
        TranslateHeader.showsHistory(
            keepHistory: vm.translator.defaults.bool(forKey: NotchViewModel.translateKeepHistoryKey)
        )
    }

    /// Geometry identities shared between the pill and the open panel.
    ///
    /// Named rather than inline so both ends cannot drift apart silently: a
    /// `matchedGeometryEffect` whose two ids stop matching does not fail, it
    /// just quietly goes back to being two objects that fade past each other,
    /// which is exactly the bug this replaced.
    enum MorphID {
        static let artwork = "island.artwork"
        static let equalizer = "island.equalizer"

        /// The pill's end of a travel, while it is showing — and a name nothing
        /// else answers to while it is folded.
        ///
        /// The compact header stays mounted when the pill folds into the notch,
        /// so without this its hidden cover, 22 pt at the notch's left edge,
        /// was still the near end of the cover's travel: opening the panel on a
        /// settled pause grew the cover out of the notch's edge and slid the
        /// bars in from the other, where before a folded pill had no end at all
        /// and both simply faded in with the pane (found in review,
        /// 2026-09-21). Renamed rather than unmounted, so the view keeps its
        /// identity and the fold keeps its motion.
        static func compact(_ id: String, folded: Bool) -> String {
            folded ? id + ".folded" : id
        }
    }

    /// The space the pill and the panel share. Declared here because this view
    /// is the nearest common ancestor of both ends — the compact header above
    /// and `MediaPane` below — and a namespace is only worth what its two ends
    /// can both see.
    @Namespace private var morph

    /// Whether the cover and the equalizer fly between the pill and the panel.
    ///
    /// Not under Reduce Motion. The shell's own open was already reduced, but
    /// the cover still morphed across the panel inside it, 22 pt to 118 pt in
    /// the reduced open's time — the largest travel on screen, left untouched
    /// by the setting that refuses travel (F-055). With no namespace each end
    /// is a lone view: the pill's cover leaves with the compact header and the
    /// panel's arrives with its pane, both fades. The lock path passes `nil`
    /// for the same reason, with nowhere to travel to.
    nonisolated static func travels(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// The namespace both ends travel in, or none when nothing may travel.
    private var travellingMorph: Namespace.ID? {
        Self.travels(reduceMotion: reduceMotion) ? morph : nil
    }

    private var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    private var size: CGSize { vm.bodySize }
    @State private var isPressed = false
    private var compactActivity: CompactMediaActivity { vm.compactMediaActivity }
    /// Whether the collapsed pill is out of the notch: any activity at all —
    /// an alert, the song, or the Shelf holding files (`IslandActivity`).
    private var pillShown: Bool { vm.activity != .none }
    /// The shoulder: the open panel's, or what the shut island shows —
    /// an expanded alert's are wider than a compact activity's
    /// (`IslandShapeRadii`).
    private var topRadius: CGFloat { isOpen ? vm.openTopRadius : vm.closedTopRadius }

    // MARK: - Resting in the notch

    /// Nothing playing, the panel shut, on a Mac with a real notch.
    ///
    /// The island used to stay drawn whenever it was idle: the notch's own
    /// width, plus a 6pt concave shoulder each side and its own bottom curve.
    /// Those shoulders and corners fall *outside* the hardware cutout, so an
    /// idle Mac carried two small black ears on the menu bar beside the notch —
    /// an island with nothing to say, still saying it. At rest it now sits just
    /// inside the cutout, where no pixel exists to draw, and is indistinguishable
    /// from the notch itself. On an external display there is no cutout to hide
    /// in, so the synthetic notch stays drawn as before.
    private var restsInNotch: Bool {
        !isOpen && !pillShown && vm.geometry.isPhysical
    }

    /// The pointer is on the island, or a press is under way.
    private var isAwake: Bool { vm.isHovering || isPressed }

    /// Hidden at rest, awake under the pointer, and everything else as before.
    private var shapeTopRadius: CGFloat {
        restsInNotch && !isAwake ? 0 : topRadius
    }

    private var shapeBottomRadius: CGFloat {
        // The surface's own: 34 for the Shelf's two, 44 for every other
        // (spec §19.6–§19.8). The shape animates its radii, so they spring with
        // the body when one surface turns into another.
        if isOpen { return vm.openBottomRadius }
        if restsInNotch && !isAwake { return Theme.restingNotchBottomRadius }
        // The peek's taller island takes 16, each expanded alert its own
        // (§19.5), every compact activity 12.67 — whichever is drawn, since
        // an alert replaces what it outranks.
        return IslandShapeRadii.closed(for: vm.activity).bottom
    }

    /// The island's surface: black, or `#1C1C1E` while the pointer is on it
    /// or a press is under way (spec §3.2). One solid fill rather than a lift
    /// painted over the black — nothing about a playing island moves, only its
    /// colour answers the pointer, and the resting notch growing out of the
    /// cutout takes the same colour. Open, the panel is always black.
    ///
    /// Not an overlay on the wings that stops at the cutout, as the old lift
    /// was: that existed to keep a pale rectangle out of the camera housing,
    /// and the housing is not a display — there is no pixel inside the cutout
    /// for the fill to light, so the whole shape can be one colour.
    private var shapeFill: Color {
        !isOpen && isAwake ? Theme.islandHover : Color.black
    }

    // MARK: - Stroke (spec §19.2)

    /// Whether the island draws its stroke: whenever the shape is out of the
    /// notch, on every wallpaper — never on the bare notch.
    private var strokeShown: Bool {
        IslandStroke.isShown(isOpen: isOpen, activityShowing: pillShown, notchAwake: restsInNotch && isAwake)
    }

    /// The activity's tint at 0.21, or white at 0.14 (0.42 and 0.30 under
    /// Increase Contrast).
    private var strokeColor: Color {
        IslandStroke.color(
            tint: IslandStroke.tint(for: vm.activity, isOpen: isOpen),
            increaseContrast: appearance.increaseContrast
        )
    }

    private var shapeSize: CGSize {
        guard restsInNotch else {
            return CGSize(width: size.width + 2 * topRadius, height: size.height)
        }
        return isAwake
            ? Self.awakeShape(notch: size, shoulder: topRadius)
            : Self.restingShape(notch: size)
    }

    /// The resting island: a point inside the cutout on every visible edge,
    /// so nothing of it lands on a pixel. Pure, so the "invisible at rest"
    /// promise is a test rather than a hope — `RestingNotchTests`.
    static func restingShape(notch: CGSize) -> CGSize {
        CGSize(
            width: notch.width - 2 * NotchMetrics.restingInset,
            height: notch.height - NotchMetrics.restingInset
        )
    }

    /// Awake under the pointer: out past the notch on both sides and a little
    /// below, with the shoulders back, so the notch visibly becomes the island.
    static func awakeShape(notch: CGSize, shoulder: CGFloat) -> CGSize {
        CGSize(
            width: notch.width + 2 * (shoulder + NotchMetrics.hoverNudgeWidth),
            height: notch.height + NotchMetrics.hoverNudgeDepth
        )
    }

    var body: some View {
        if vm.isLockedPresentation {
            // One layer with the shield up: the pill where it always lives —
            // visible, never opening, the island refusing to disappear just
            // because the desktop did. The player is a window of its own.
            lockedPill
            // Held to the whole panel, top-aligned. The panel is anchored to
            // the notch, so the top of this window *is* the cutout — and a
            // stack left to hug a 32 pt pill gets centred in 444 pt instead,
            // which floats the island two hundred points down the lock screen,
            // over the clock. The card used to force this fill; it has a window
            // of its own now, so the fill has to be stated.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Nothing here animates from the layout it had a moment ago. Locking
            // while the panel was open leaves an open→closed animation in
            // flight, and swapping the whole view tree under it made SwiftUI
            // interpolate the card and the pill *from* the old 700×444 notch
            // window — visibly sliding in from the left, at the wrong size, for
            // the length of that animation. The lock screen is a cut, not a
            // transition. The one motion allowed in here is the pill's own fold,
            // and it is declared inside `lockedPill`, beneath this refusal, so it
            // can answer a pause without ever animating the lock.
            .animation(nil, value: vm.isLockedPresentation)
            .transaction { $0.animation = nil }
        } else {
            // The island first, then the bubble: the order VoiceOver reads
            // them in (spec §19.12).
            ZStack(alignment: .top) {
                shell
                bubbleLayer
            }
        }
    }

    // MARK: - The bubble (spec §19.7)

    /// The Shelf waiting beside Music, 16 right of the island's outline. It
    /// arrives and leaves as compact content does, and follows the island's
    /// edge on the outline's spring as the island changes width. The rest of
    /// this window-sized layer is empty and takes no clicks; the bubble's own
    /// are cut by `NotchRootView.bubbleRect`.
    private var bubbleLayer: some View {
        ZStack(alignment: .top) {
            if let count = vm.bubbleCount {
                IslandBubble(count: count, height: size.height, increaseContrast: appearance.increaseContrast) {
                    vm.onBubbleClick?()
                }
                .offset(x: IslandBubbleLayout.centreOffset(islandWidth: size.width, count: count))
                .transition(Theme.compactArrival(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.bubbleCount != nil)
        .animation(Theme.island(reduceMotion: reduceMotion), value: size.width)
        // A tenth file widens it by a digit, on the same spring.
        .animation(Theme.island(reduceMotion: reduceMotion), value: IslandBubbleLayout.digits(vm.bubbleCount ?? 0))
    }

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
    private var lockedPill: some View {
        // The wings are the island's own and the banner or the card is the
        // song's: while it is up the island rests in the notch, wherever the
        // song is playing (spec §3.7, owner decision 1; `LockedIsland`).
        let shown = vm.lockedIslandShowsWings
        let notch = vm.geometry.notchSize
        // The notch the banner or the card leaves alone still answers: a hover
        // wakes it as it wakes any resting notch, and a click shakes it. Only over
        // a real cutout — a display without one draws no resting island to wake.
        let answers = vm.lockSurfacePresentsSong && vm.geometry.isPhysical
        let awake = !shown && answers && vm.isHovering
        let out = shown || awake
        let shape = shown
            ? CGSize(width: size.width + 2 * Theme.collapsedTopRadius, height: notch.height)
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
            if shown {
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

    private var shell: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
            .fill(shapeFill)
            .frame(width: shapeSize.width, height: shapeSize.height)
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

            // Over the black and centred on its edge, so half the line lies
            // outside the shape and half inside. Always mounted and faded,
            // never inserted, so it folds and unfolds with the shape instead
            // of arriving after it, and built from the same radii and the same
            // frame, so it follows the outline through every spring.
            IslandStrokeShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
                .stroke(strokeColor, lineWidth: Theme.islandStrokeWidth)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .opacity(strokeShown ? 1 : 0)
                .allowsHitTesting(false)

            // The shape is the only black. A second black layer used to sit
            // over the wings, faded out on its own 0.12 s while the shape
            // contracted — and a removed view keeps the frame it had, so for
            // the first tenth of every fold the pill's full outline stayed on
            // screen, dimming, over a shape already moving in. A fold that
            // begins as a fade is not a fold. Both layers were plain black by
            // then, so the one that could not move is the one that went.

            VStack(spacing: 0) {
                header
                if isOpen {
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
            // Square at rest, as it always was. Between two pages the one
            // arriving passes the outline's bottom corners, and is clipped by
            // them rather than drawn over the wallpaper beside them (§19.16).
            .clipShape(NotchShape(topRadius: 0, bottomRadius: vm.travellingLeg == nil ? 0 : shapeBottomRadius))
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
        // Out of the notch and back into it, on the outline's spring both ways
        // (spec §19.3) — see `Theme.pill`. The peek and the charger are the same
        // gesture made wider, so they ride it too.
        .animation(Theme.pill(reduceMotion: reduceMotion), value: compactActivity)
        .animation(Theme.pill(reduceMotion: reduceMotion), value: vm.isPeeking)
        .animation(Theme.pill(reduceMotion: reduceMotion), value: vm.ambient)
        // The pop-up widens and folds on the outline's spring (spec §19.3).
        // Keyed to whether it is up, not to its level: a press only moves the
        // bar, which has a curve of its own.
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.hud != nil)
        // The Shelf as the live activity coming and going, and its count
        // changing (spec §19.4) — a file kept with the panel shut. Keyed to
        // the live count, not the Shelf's: a collected file's moment begins
        // and ends with no change to the count — at the Shelf's limit a
        // capture adds one card and evicts one — and the island jumped in and
        // out of the notch without its spring (R7 review).
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.liveShelfCount)
        .animation(Theme.paneAnimation, value: vm.presented)
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
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. No controls go in this row —
    // the tab switcher lives in the rail below — and the one gesture it answers
    // is the one the island already owns: the click that shuts the panel.

    @ViewBuilder
    private var header: some View {
        if isOpen {
            openHeader
        } else {
            // Mounted whenever the panel is shut — folded into the notch too,
            // drawn at nothing there. A pill that was only in the tree while it
            // showed could not fold: removed, a view keeps the frame it had,
            // so its cover sat still at the old width while the edge swept in
            // over it and sliced it. Kept, it rides the wings as they contract
            // and dissolves on its own curve; see `compactMediaHeader`.
            //
            // This transition is load-bearing, and not for the reason it looks
            // like. A removed view with a transition stays in the tree until the
            // transition ends; a removed view with `.identity` is gone the
            // instant the flag flips. The cover and the equalizer travel from
            // *here* to the open panel, and `matchedGeometryEffect` can only
            // interpolate between two views that are both in the tree for the
            // same transaction. Take this transition away and the morph does not
            // break loudly — it silently goes back to being a crossfade.
            ZStack {
                // The music stays mounted under the moment, faded rather than
                // removed, so the cover's morph and the fold described above
                // are exactly as they were when the moment ends.
                compactMediaHeader(morph: travellingMorph)
                    .opacity(vm.ambient == nil && vm.hud == nil ? 1 : 0)
                // One activity at a time, the highest first (`IslandActivity`):
                // an alert replaces what it outranks, and the replaced one is
                // gone, not waiting underneath (spec §19.1).
                switch vm.activity {
                case .hud(let hud):
                    hudHeader(hud)
                        .transition(Theme.expandedArrival(reduceMotion: reduceMotion))
                case .ambient(let ambient):
                    ambientHeader(ambient)
                        .transition(ambientArrival(ambient))
                case .shelf(let count):
                    shelfHeader(count: count)
                        .transition(Theme.compactArrival(reduceMotion: reduceMotion))
                case .peek, .music, .none:
                    EmptyView()
                }
            }
            // The island to assistive tech, on the stack that holds both the
            // music and the moment, so that a peek or a charger changes this
            // element's value rather than swapping one element for another.
            .modifier(islandAccessibility(open: false))
            .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
        }
    }

    /// The charger is a compact activity and arrives as one; headphones are
    /// an expanded alert and arrive as one (spec §19.3).
    private func ambientArrival(_ ambient: AmbientActivity) -> AnyTransition {
        switch ambient {
        case .charging: return Theme.compactArrival(reduceMotion: reduceMotion)
        case .headphones: return Theme.expandedArrival(reduceMotion: reduceMotion)
        }
    }

    /// What the island is to VoiceOver and Switch Control: one button called
    /// Isla, in every state the island has, whose value says what it shows.
    ///
    /// The element used to live inside the music header and was hidden while
    /// the pill was folded, on the reasoning that a folded pill has nothing on
    /// screen to describe. But the island is not only a display: it is the one
    /// way into the app, which has no Dock icon, no menu-bar item and no
    /// window. With nothing playing the tree held only the hosting view, and a
    /// blind user could neither find Isla nor open it — while the welcome told
    /// them to click it (H-001). So the island is always there now, with
    /// "Nothing is playing." as its value when that is the truth.
    ///
    /// Open, the same element sits on the header strip — the strip a pointer
    /// clicks to shut the panel — and says so. A panel opened from assistive
    /// tech is pinned open, and nothing in it used to close it again: the
    /// strip was a bare tap gesture with no trait and no action (G-015).
    ///
    /// Accessibility modifiers do not change layout, so the matched-geometry
    /// ids and the fold are untouched, and the strip stays free of controls
    /// for the pointer: menu-bar monitors such as Ice see exactly what they
    /// saw before.
    private func islandAccessibility(open: Bool) -> IslandAccessibility {
        IslandAccessibility(
            value: open ? openIslandValue : closedIslandValue,
            hint: open ? localized("Closes the panel") : localized("Opens the panel"),
            action: {
                // Locked, the same refusal a click gets — the shake and the
                // spoken "Unlock your Mac to open Isla." It used to return
                // silently, which to someone who cannot see the pill was a
                // button that did nothing at all.
                guard !vm.isLockedPresentation else {
                    vm.nudgeLockedIsland()
                    return
                }
                vm.onIslandClick?()
            }
        )
    }

    /// The shut island's value: the moment if one is up, else the track, else
    /// that there is none. The locked pill draws no moment, so over the shield
    /// it does not name one.
    private var closedIslandValue: String {
        if !vm.isLockedPresentation, let hud = vm.hud { return hud.accessibilityLabel }
        if !vm.isLockedPresentation, let ambient = vm.ambient { return ambient.accessibilityLabel }
        if !vm.isLockedPresentation, case .shelf(let count) = vm.activity { return localized("Shelf, %d items", count) }
        return vm.media.track == nil ? localized("Nothing is playing.") : compactAccessibilityLabel
    }

    /// The open island's value: the surface on screen, and the count or the
    /// player beside it where it has one.
    private var openIslandValue: String {
        let surface = vm.presented
        let detail: String?
        switch surface {
        case .player, .stage: detail = vm.media.sourceName
        case .tray: detail = vm.shelf.items.isEmpty ? nil : "\(vm.shelf.items.count)"
        case .clipboard: detail = nil
        case .drop, .translate, .settings, .welcome: detail = nil
        }
        guard let detail, !detail.isEmpty else { return surface.title }
        return "\(surface.title), \(detail)"
    }

    /// The charger or the headphones on the island.
    @ViewBuilder
    private func ambientHeader(_ ambient: AmbientActivity) -> some View {
        switch ambient {
        case .charging(let level, _):
            // `showsOnIsland` keeps a Mac with no level off the island; the
            // guard is for the type, not a state that is drawn.
            if let level { chargingHeader(ambient, level: level) }
        case .headphones(let name, let symbol):
            headphonesHeader(name: name, symbol: symbol)
        }
    }

    /// Charging (spec §19.4): "Charging" in the left wing, 14 regular, white
    /// 0.88, from 18.5; in the right the level, 14 regular in the green
    /// gradient, 6 pt, and a drawn battery ending 19.3 from the edge. A battery
    /// that only holds is not charging, so it says nothing it would have to
    /// take back: the plug in the word's place, and the level and battery in
    /// white — as its stroke is white (`IslandStroke.tint`).
    private func chargingHeader(_ ambient: AmbientActivity, level: Int) -> some View {
        let charging = ambient.usesChargingGreen
        let scale = CompactIslandLayout.glyphScale(height: size.height)
        let tone: AnyShapeStyle = charging ? AnyShapeStyle(Theme.chargingGreen.gradient) : AnyShapeStyle(Color.white)
        let track = (charging ? Theme.chargingGreen : Color.white).opacity(CompactIslandLayout.batteryTrackOpacity)
        return HStack(spacing: 0) {
            Group {
                if charging {
                    Text(localized("Charging"))
                        .islandFont(CompactIslandLayout.chargingTextSize)
                        .foregroundStyle(Color.white.opacity(CompactIslandLayout.chargingTextOpacity))
                        .lineLimit(1)
                } else {
                    Image(systemName: ambient.chargeSymbol)
                        .font(.system(size: CompactIslandLayout.chargingTextSize * scale, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.leading, CompactIslandLayout.chargingTextInset)
            Spacer(minLength: 0)
            Text(localized("%d%%", level))
                .font(.system(size: CompactIslandLayout.chargingTextSize).monospacedDigit())
                .tracking(Theme.tracking(forSize: CompactIslandLayout.chargingTextSize))
                .foregroundStyle(tone)
                .lineLimit(1)
                .fixedSize()
            IslandBattery(level: level, fill: tone, track: track, scale: scale)
                .padding(.leading, CompactIslandLayout.levelToBatteryGap)
                .padding(.trailing, CompactIslandLayout.batteryTrailing - CompactIslandLayout.shoulder)
        }
        .frame(width: size.width, height: size.height)
        // No element of its own: the moment is the island's value, set on the
        // stack above it — see `islandAccessibility(open:)`.
    }

    /// Headphones connected (spec §19.5 c), an expanded alert: the device's
    /// own symbol, hierarchical, at left; "Connected" over the device's name
    /// beside it, the name truncating at its tail. The battery ring waits for
    /// a level Isla can read without a new permission (§19.15, R9), so the
    /// name takes its width.
    private func headphonesHeader(name: String, symbol: String) -> some View {
        let notchHeight = vm.geometry.notchSize.height
        let glyph = HeadphonesAlertLayout.glyphFrame(notchHeight: notchHeight)
        return ZStack(alignment: .topLeading) {
            Image(systemName: symbol)
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .scaledToFit()
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.glyphOpacity))
                .frame(width: glyph.width, height: glyph.height)
                .offset(x: glyph.minX, y: glyph.minY)
            Text(localized("Connected"))
                .islandFont(HeadphonesAlertLayout.connectedSize)
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.connectedOpacity))
                .lineLimit(1)
                .islandBaseline(HeadphonesAlertLayout.connectedBaseline(notchHeight: notchHeight))
                .offset(x: HeadphonesAlertLayout.textLeading)
            Text(name)
                .islandFont(HeadphonesAlertLayout.nameSize)
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.nameOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: HeadphonesAlertLayout.nameWidth(islandWidth: size.width), alignment: .leading)
                .islandBaseline(HeadphonesAlertLayout.nameBaseline(notchHeight: notchHeight))
                .offset(x: HeadphonesAlertLayout.textLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The Shelf holding files (spec §19.4): `tray.full.fill`, white, 26 × 20
    /// at (17.3, 9); the count in SF Pro Rounded 16, tabular, white, ending
    /// 18.3 from the edge. The live activity when nothing plays.
    private func shelfHeader(count: Int) -> some View {
        let tray = CompactIslandLayout.shelfGlyphFrame(height: size.height)
        return HStack(spacing: 0) {
            Image(systemName: "tray.full.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
                .frame(width: tray.width, height: tray.height)
                .padding(.leading, tray.minX)
            Spacer(minLength: 0)
            Text(count, format: .number)
                .font(.system(size: CompactIslandLayout.shelfCountFontSize, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .contentTransition(.numericText(value: Double(count)))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, CompactIslandLayout.shelfCountTrailingInset)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The volume or brightness pop-up (spec §19.5 d), an expanded alert: the
    /// output's name — or which brightness — over a row of the symbol, the
    /// bar and the level as a number. The bar fills in amber with a glow;
    /// muted, white 0.32 at the level it will return to, no glow. It steps on
    /// `hudLevel` per press; under Reduce Motion it steps without gliding.
    private func hudHeader(_ hud: HUDMoment) -> some View {
        let notchHeight = vm.geometry.notchSize.height
        let track = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: notchHeight)
        let symbol = HUDLayout.symbolFrame(notchHeight: notchHeight)
        let fill: AnyShapeStyle = hud.muted
            ? AnyShapeStyle(Color.white.opacity(HUDLayout.mutedFillOpacity))
            : AnyShapeStyle(LinearGradient(
                colors: [Theme.hudAmber.opacity(HUDLayout.fillStartOpacity), Theme.hudAmber],
                startPoint: .leading, endPoint: .trailing
            ))
        return ZStack(alignment: .topLeading) {
            Text(hud.title)
                .islandFont(HUDLayout.titleSize)
                .foregroundStyle(Color.white.opacity(HUDLayout.titleOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: HUDLayout.titleWidth(islandWidth: size.width), alignment: .leading)
                .islandBaseline(HUDLayout.titleBaseline(notchHeight: notchHeight))
                .offset(x: HUDLayout.titleLeading)
            Image(systemName: hud.symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
                .frame(width: symbol.width, height: symbol.height)
                .offset(x: symbol.minX, y: symbol.minY)
            RoundedRectangle(cornerRadius: HUDLayout.barRadius, style: .continuous)
                .fill(Color.white.opacity(HUDLayout.trackOpacity))
                .frame(width: track.width, height: track.height)
                .offset(x: track.minX, y: track.minY)
            RoundedRectangle(cornerRadius: HUDLayout.barRadius, style: .continuous)
                .fill(fill)
                .shadow(
                    color: hud.muted ? .clear : Theme.hudAmber.opacity(HUDLayout.glowOpacity),
                    radius: HUDLayout.glowRadius
                )
                .frame(width: track.width * CGFloat(hud.level), height: track.height)
                .offset(x: track.minX, y: track.minY)
                .animation(Theme.hudLevel(reduceMotion: reduceMotion), value: hud.level)
            // Centred on the bar, its right edge on the reference's 34.5.
            Text(hud.percent, format: .number)
                .font(.system(size: HUDLayout.numberSize, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(HUDLayout.numberOpacity))
                .contentTransition(.numericText(value: Double(hud.percent)))
                .lineLimit(1)
                .fixedSize()
                .frame(width: max(0, size.width - HUDLayout.numberTrailingInset), height: track.height,
                       alignment: .trailing)
                .offset(y: track.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // No element of its own: like the other moments, the pop-up is the
        // island's value (`closedIslandValue`), set on the stack above it.
    }

    /// The open panel's header strip (spec §19.6–§19.8): the notch's height,
    /// with the surface's title or glyph left of the notch and its tools
    /// right of it, each centred on the strip.
    ///
    /// Only the notch's own span closes the panel. The strip used to close on
    /// a click anywhere, which was safe while nothing in it was a control; the
    /// surfaces carry Tools, History, Remove All and Settings here now, and a
    /// click a few points beside one must not shut the panel out from under
    /// the pointer. The span is where the island is, so a click on the island
    /// still answers as it always has.
    private var openHeader: some View {
        let notch = vm.geometry.notchSize
        let span = SurfaceHeaderLayout.closeSpan(bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height)
        return ZStack(alignment: .topLeading) {
            Color.clear
            // The close, and the island to assistive tech: the same Isla button
            // the shut island is, which says it closes (G-015).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.onIslandClick?() }
                .modifier(islandAccessibility(open: true))
                .placedAt(span)
            headerLeading(notch: notch)
            headerTrailing(notch: notch)
        }
        .frame(width: size.width, height: notch.height, alignment: .topLeading)
        .animation(Theme.contentAnimation, value: vm.presented)
    }

    @ViewBuilder
    private func headerLeading(notch: CGSize) -> some View {
        switch vm.presented {
        case .clipboard, .translate, .settings:
            if let symbol = vm.presented.symbol {
                SurfaceHeaderTitle(symbol: symbol, title: vm.presented.title)
                    .placedAt(SurfaceHeaderLayout.title(
                        bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height
                    ))
                    .transition(.opacity)
            }
        case .stage:
            // The playing app's icon: where the words come from, in the place
            // the board gives it.
            if let icon = vm.media.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .placedAt(SurfaceHeaderLayout.stageIcon(notchHeight: notch.height))
                    .accessibilityLabel(vm.media.sourceName ?? "")
                    .transition(.opacity)
            }
        case .tray:
            let count = vm.shelf.items.count
            Image(systemName: "tray.full.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
                .placedAt(SurfaceHeaderLayout.trayGlyph(notchHeight: notch.height))
                .accessibilityHidden(true)
                .transition(.opacity)
            if ShelfHeader.showsCount(itemCount: count) {
                Text(count, format: .number)
                    .font(.system(size: ShelfLayout.headerCountSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .contentTransition(.numericText(value: Double(count)))
                    .lineLimit(1)
                    .placedAt(SurfaceHeaderLayout.trayCount(
                        bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height
                    ))
                    .accessibilityLabel(ShelfHeader.countText(count))
                    .transition(.opacity)
            }
        case .player, .drop, .welcome:
            EmptyView()
        }
    }

    @ViewBuilder
    private func headerTrailing(notch: CGSize) -> some View {
        let gear = SurfaceHeaderLayout.gear(bodyWidth: size.width, notchHeight: notch.height)
        switch vm.presented {
        case .tray:
            if ShelfHeader.showsRemoveAll(itemCount: vm.shelf.items.count) {
                let width = ShelfRemoveAllButton.width()
                ShelfRemoveAllButton { vm.askToRemoveAll() }
                    .placedAt(SurfaceHeaderLayout.removeAll(bodyWidth: size.width, width: width, notchHeight: notch.height))
                    .transition(.opacity)
            }
            gearButton.placedAt(gear)
        case .translate:
            if translateKeepsHistory {
                HeaderToolButton(
                    symbol: "clock.arrow.circlepath", label: localized("History"), isOn: vm.translateShowsHistory
                ) { vm.translateShowsHistory.toggle() }
                .placedAt(SurfaceHeaderLayout.history(bodyWidth: size.width, notchHeight: notch.height))
                .transition(.opacity)
            }
            gearButton.placedAt(gear)
        case .player, .stage, .clipboard, .settings:
            gearButton.placedAt(gear)
        case .drop, .welcome:
            EmptyView()
        }
    }

    /// The gear (spec §19.16), where the Tools button stood: Settings from a
    /// page or the stage on the island's spring, and on Settings, lit, the way
    /// back. It carries the update badge Tools' own gear carried, so an update
    /// waiting shows on every page.
    private var gearButton: some View {
        HeaderToolButton(
            symbol: "gearshape", label: localized("Settings"),
            isOn: vm.presented == .settings, badge: updates.hasUpdate
        ) {
            withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.pressGear() }
        }
        .transition(.opacity)
    }

    /// - Parameter morph: the namespace the cover and the equalizer travel in,
    ///   or `nil` where there is nowhere for them to travel to — over the lock
    ///   screen, where this pill is the only thing on screen.
    ///
    /// The cover is 8 pt from the island's left edge and the equalizer's last
    /// bar 8 pt from its right (spec §3.1), both centred in the island's height
    /// — on the 38 pt notch that is the "7 from the bottom" the board draws, and
    /// on the peek's 50 pt it is the 8 the peek's cover is inset. Pinned to the
    /// island's own edges rather than centred in a wing, so the margins are the
    /// same on a notch of any width.
    ///
    /// Both wing objects stay laid out while the pill is folded, still against
    /// the edges of a shape that contracts to the notch. That is what makes a
    /// fold read as the island taking them in: as the wings contract the cover
    /// and the bars travel inward with their edges, and `pillPresence` dissolves
    /// them — blur, scale and fade together — on a curve that finishes before
    /// the edge arrives.
    private func compactMediaHeader(morph: Namespace.ID?) -> some View {
        let shown = compactActivity.isVisible
        let notchWidth = vm.geometry.notchSize.width
        return HStack(spacing: 0) {
            compactArtwork(morph: morph)
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.leading, CompactIslandLayout.coverInset)
            // Only while peeking, and only in the left wing on a real notch
            // (see `CompactIslandLayout.peekTextWidth`): the title is what the
            // peek exists to show, and the right wing keeps the equalizer so
            // the island still says whether audio is moving.
            if vm.isPeeking, let track = vm.media.track {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .islandFont(.subhead, weight: .semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(track.artist)
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(
                    width: CompactIslandLayout.peekTextWidth(
                        islandWidth: size.width, notchWidth: notchWidth, isPhysical: vm.geometry.isPhysical
                    ),
                    alignment: .leading
                )
                // The title materializes rather than fading flat: the same
                // blur-and-settle the cover makes arriving. And it dissolves
                // with the cover when the pill folds — a pause settling
                // mid-peek used to fold the island in over a title still at
                // full strength, slicing it.
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.leading, 10)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
            Spacer(minLength: 0)
            compactPlaybackState(morph: morph)
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.trailing, CompactIslandLayout.equalizerTrailingInset)
                // No gesture here, deliberately.
                //
                // The equalizer wing used to toggle playback, from when a hover
                // opened the panel and a click had no other meaning. Now that a
                // click *is* how the island opens, a wing that did something
                // else gave the compact island two behaviours with nothing
                // visible marking the boundary — press one half and it opens,
                // press the other and the music stops.
                //
                // The compact island has no controls at all. It shows what is
                // playing, and clicking anywhere on it opens the panel, where
                // the controls actually are.
        }
        .frame(width: size.width, height: size.height)
        // No element of its own. It was one, hidden while folded, and so with
        // nothing playing the island did not exist to VoiceOver at all; the
        // island's one element now sits on whatever holds this header — see
        // `islandAccessibility(open:)`. Its single purpose is still opening:
        // a Pause action here would be a button the compact island does not
        // have, reachable only by people who cannot see that it has none.
    }

    /// The near end of the cover's travel.
    ///
    /// It used to be a second cover: 22 pt here (24 since the redesign), 118 pt in `MediaPane`, each
    /// fading on its own schedule, so opening the panel crossfaded one album
    /// past itself. The two are one object now, and the pieces that make it one
    /// are worth naming, because none of them announces itself when it breaks:
    ///
    /// - `Theme.artworkMetrics` describes both ends, so they cannot disagree
    ///   about size or silhouette.
    /// - The base is `Color.clear` and the picture rides above it. The cover has
    ///   to accept whatever size it is offered — the morph offers it the panel's
    ///   118 pt on the way out — and anything that states a size of its own is
    ///   something the effect cannot resize, leaving a cover that slides across
    ///   without ever growing. `Color.clear` takes the proposal exactly and the
    ///   clip below cuts the overflow off, which `scaledToFill` needs badly: a
    ///   16:9 cover reports itself 39 pt wide in this 22 pt slot and would hang
    ///   over the notch. `.frame(maxWidth: .infinity)` is not a substitute — it
    ///   grows to whatever the child reports, taking the clip with it.
    /// - `.morph` sits **inside** the outer frame, so the frame keeps reserving
    ///   the cover's side in the wing while the cover itself is somewhere between here and
    ///   the panel.
    /// - The image carries no `.transition(.opacity)` of its own any more. A
    ///   travelling object that fades while it travels is a crossfade wearing a
    ///   morph's clothes, and the default transition already crossfades one
    ///   album into the next when the track changes.
    private func compactArtwork(morph: Namespace.ID?) -> some View {
        // 22 pt at radius 5 resting (16 at 4 on the short island), 34 at 8
        // while a track peeks: one cover in three sizes, and the frame
        // interpolates between them on the same curve the island grows on.
        let metrics = vm.isPeeking && compactActivity.isVisible
            ? Theme.peekArtworkMetrics
            : (side: CompactIslandLayout.coverSide(height: size.height),
               cornerRadius: CompactIslandLayout.coverRadius(height: size.height))
        return Color.clear
            .overlay {
                Group {
                    if let artwork = vm.media.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .id(vm.media.track?.key)
                    } else {
                        // A well and a note (spec §3.2): the left wing is never
                        // a hole, and never a second, different kind of cover.
                        Theme.coverWell
                            .overlay {
                                Image(systemName: "music.note")
                                    .islandFont(.body, weight: .regular)
                                    .foregroundStyle(Theme.secondary)
                            }
                    }
                }
                // Paused darkens the cover to 0.55 of itself. It was 0.58
                // opacity, which let a bright wallpaper through the picture —
                // a paused cover on a pale desktop read as a ghost — where a
                // multiply darkens it over anything.
                .colorMultiply(showsPausedCover ? Color(white: Theme.pausedCoverBrightness) : .white)
            }
            .overlay {
                if showsPausedCover {
                    // A bare glyph on the dimmed cover, 9 pt, white, with a
                    // faint shadow for the one cover that is nearly white. The
                    // 15 pt black badge this replaces was a second object on a
                    // 22 pt cover; the glyph is fitted to the cover, not type,
                    // so no role applies and the caption floor would be too
                    // large for it.
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .offset(x: 0.5)
                        .transition(Theme.scaleIn(0.82, reduceMotion: reduceMotion))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
            .morph(MorphID.compact(MorphID.artwork, folded: !compactActivity.isVisible), in: morph)
            .frame(width: metrics.side, height: metrics.side)
            .animation(Theme.contentAnimation, value: showsPausedCover)
    }

    /// The paused cover, kept through the fold.
    ///
    /// `.paused` is the only state that draws the badge, and a settled pause is
    /// `.hidden` — so every fold began by brightening the cover back to full
    /// and popping its badge off: a flash of "playing" on the way into the
    /// notch. Paused is what the player says, not what the pill is doing.
    private var showsPausedCover: Bool {
        Self.showsPausedCover(activity: compactActivity, isPlaying: vm.media.isPlaying)
    }

    static func showsPausedCover(activity: CompactMediaActivity, isPlaying: Bool) -> Bool {
        activity.showsArtworkPlayBadge || (!activity.isVisible && !isPlaying)
    }

    /// The equalizer travels too, and it is the easier half: the pill's bars
    /// are carried to the open header's right end, so the bars never vanish on
    /// one side of the notch and reappear on the other — which reads as two
    /// equalizers for one piece of music.
    ///
    /// Six bars in the cover's tint as a gradient while music plays; at rest,
    /// 3 pt tall in tertiary, when it is paused (spec §19.4, §3.2). Three
    /// quarters of its size on the short island, scaled rather than re-laid,
    /// so the far end of the morph is the same view at the same proportions.
    private func compactPlaybackState(morph: Namespace.ID?) -> some View {
        let scale = CompactIslandLayout.glyphScale(height: size.height)
        let side = CompactIslandLayout.equalizerSide * scale
        return CompactEqualizer(
            isAnimating: compactActivity.animatesEqualizer,
            colors: CompactEqualizerMotion.colors(
                isPlaying: compactActivity.tintsEqualizer,
                tint: vm.coverTint.nsColor,
                increaseContrast: appearance.increaseContrast
            )
        )
        .scaleEffect(scale)
        .frame(width: side, height: side)
        .morph(MorphID.compact(MorphID.equalizer, folded: !compactActivity.isVisible), in: morph)
    }

    /// The view model's, because the peek announces the same sentence.
    private var compactAccessibilityLabel: String { vm.compactAccessibilityLabel }

    // MARK: - Body

    private var content: some View {
        let headerHeight = vm.geometry.notchSize.height
        return ZStack(alignment: .topLeading) {
            panes
                .frame(
                    width: size.width,
                    // A page's dots have their own band under it (§19.16): the
                    // pane ends above the band, so no list or card runs under them.
                    height: max(0, size.height - headerHeight - SurfaceLayout.dotsBand(for: vm.presented)),
                    alignment: .topLeading
                )
                // Between two pages the taller arriving one would run on into
                // the band, under the dots; cut there while they travel. At
                // rest nothing is cut, as before.
                .clipShape(PaneClip(isCutting: vm.travellingLeg != nil))
            // After the pages, so VoiceOver reads the row after the page.
            if vm.presented.isPage {
                PageDots(
                    current: PageDots.current(leg: vm.travellingLeg, presented: vm.presented),
                    bodySize: size, headerHeight: headerHeight,
                    turn: { vm.travel(to: $0, reduceMotion: reduceMotion) },
                    adjust: { vm.adjustPage(by: $0, reduceMotion: reduceMotion) }
                )
                .accessibilitySortPriority(-1)
                .transition(.opacity)
            }
        }
            .frame(width: size.width, height: max(0, size.height - headerHeight), alignment: .topLeading)
            // A sideways swipe anywhere over a page turns it (§19.16).
            .onPageSwipe(enabled: vm.presented.isPage && !vm.isLockedPresentation) { event, over in
                vm.pageScroll(event, over: over)
            }
            // VO-Escape, or Switch Control's Escape, anywhere in the body closes
            // the panel, as the header does. A panel opened from assistive tech is
            // pinned open, and the pin ends only on a real mouse-down in another
            // app, so without this the only way out was the global hot key —
            // which someone who opened Isla by its button may not know (G-015).
            .accessibilityAction(.escape) { vm.onIslandClick?() }
    }

    private var panes: some View {
        // At rest, one pane: the presented surface, replaced in place with the
        // slight zoom that is the only travel a swap has; Reduce Motion takes
        // it, and the swap is a plain crossfade (F-017). The body's own size
        // springs on the island's curve underneath (`openBodySize`).
        //
        // Between two pages (§19.16), the two either side of the travel, side
        // by side, each at its own size, moved by exactly the travel and
        // clipped by the outline. One `ForEach` keyed by the surface for both,
        // so the page on screen when a swipe begins stays the view it was —
        // its scroll, its field, its hover — and the neighbour joins it, and
        // later leaves, with no transition: it is off the outline when it does.
        let scales = Theme.paneSwapScales(reduceMotion: reduceMotion)
        let leg = vm.travellingLeg
        let shown = leg?.mounted ?? [vm.presented]
        return ZStack(alignment: .topLeading) {
            ForEach(shown) { surface in
                let frame = paneSize(surface)
                pane(for: surface)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .offset(x: paneX(surface, leg: leg))
                    .transition(leg != nil ? .identity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: scales.insertion))
                            .animation(Theme.paneIn),
                        removal: .opacity
                            .combined(with: .scale(scale: scales.removal))
                            .animation(Theme.paneOut)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One group, named for what it holds.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(vm.presented.title)
    }

    /// A pane's own frame: its surface's open body less the header row, and
    /// less the dots' band on a page.
    private func paneSize(_ surface: NotchViewModel.Surface) -> CGSize {
        let body = vm.openSize(of: surface)
        return CGSize(
            width: body.width,
            height: max(0, body.height - vm.geometry.notchSize.height - SurfaceLayout.dotsBand(for: surface))
        )
    }

    /// Where a pane's leading edge sits in the outline: centred, and on the
    /// way between two pages moved by exactly the travel (`PageStrip`).
    private func paneX(_ surface: NotchViewModel.Surface, leg: PageTravel.Leg?) -> CGFloat {
        guard let leg, let index = leg.strip.pages.firstIndex(of: surface) else {
            return (size.width - vm.openSize(of: surface).width) / 2
        }
        return leg.strip.x(ofPage: index, at: leg.position, outlineWidth: size.width)
    }

    /// Whether a pane drawn now is the surface on screen, or a page beside it
    /// only for a swipe's length (§19.16). Only the one on screen may hold
    /// the keyboard or start work: a neighbour that took focus on appearing
    /// would take the keyboard from the page the fingers are still on — and
    /// keep it if they went back — and Translate passed on the way would
    /// translate its text for nobody.
    nonisolated static func paneIsLive(
        _ surface: NotchViewModel.Surface, presented: NotchViewModel.Surface
    ) -> Bool {
        surface == presented
    }

    @ViewBuilder
    private func pane(for surface: NotchViewModel.Surface) -> some View {
        let bodyWidth = vm.openSize(of: surface).width
        let live = Self.paneIsLive(surface, presented: vm.presented)
        let keyboard = live ? $vm.wantsKeyboard : .constant(false)
        switch surface {
        case .player:
            // The namespace goes down with the player: the far end of the
            // cover's travel is drawn inside it, and it is the one surface that
            // has an end to offer.
            MediaPane(
                media: vm.media,
                lyrics: vm.lyrics,
                openStage: { withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.openStage() } },
                bringPlayerForward: { vm.media.bringPlayerForward() },
                openMusicOnlySetting: vm.openMusicOnlySetting,
                morph: travellingMorph,
                audio: vm.playerAudio,
                spotify: vm.spotifyAccount,
                coverTint: vm.coverTint.nsColor
            )
        case .stage:
            LyricsStageSurface(
                media: vm.media,
                lyrics: vm.lyrics,
                bodyWidth: bodyWidth,
                localLookup: vm.lyricsCoordinator.localLookup,
                turnOnLyrics: vm.turnOnLyrics,
                turnOnOnlineLyrics: vm.turnOnOnlineLyrics,
                importLocalFile: { vm.chooseLocalLyricsFile(from: .stage) },
                notice: vm.lyricsNotice?.origin == .stage ? vm.lyricsNotice?.text : nil,
                selectLocalCandidate: vm.lyricsCoordinator.selectLocalCandidate,
                removeLocalBinding: vm.lyricsCoordinator.removeLocalBinding,
                localLibrary: vm.localLyricsLibrary,
                currentLocalTrackIdentity: { vm.lyricsCoordinator.currentLocalTrackIdentity },
                invalidLine: {
                    vm.lyricsCoordinator.currentLocalTrackIdentity.flatMap { vm.localLyricsLibrary.invalidLine(for: $0) }
                },
                editingSession: $vm.lyricEditing,
                moreMenu: vm.lyricsMoreMenu,
                translateMenu: vm.lyricsTranslateMenu,
                hideLyrics: { withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.hideLyrics() } },
                audio: vm.playerAudio,
                translation: vm.translation,
                coverTint: vm.coverTint.nsColor
            )
        case .tray:
            ShelfPane(shelf: vm.shelf, clear: vm.shelfClear, bodyWidth: bodyWidth, strip: vm.shelfStrip)
        case .drop:
            ShelfDropSurface(bodyWidth: bodyWidth, dropTarget: vm.shelfDropTarget)
        case .clipboard:
            ClipboardPane(
                clipboard: vm.clipboard, privacy: vm.privacy, browser: vm.clipboardBrowser,
                bodyWidth: bodyWidth,
                wantsKeyboard: keyboard,
                translate: { vm.translateClipboardText($0) },
                clearConfirmation: vm.clipboardClear,
                turnOnHistory: { vm.setClipboardHistory(true) }
            )
        case .translate:
            TranslatePane(
                translator: vm.translator, privacy: vm.privacy, wantsKeyboard: keyboard,
                showsHistory: $vm.translateShowsHistory, bodyWidth: bodyWidth, isLive: live
            )
                .onPreferenceChange(TextInputRectKey.self) { vm.textInputRect = $0 }
        case .settings:
            SettingsPane(
                shelf: vm.shelf,
                screenshotVault: vm.screenshotVault,
                lyrics: vm.lyrics,
                media: vm.media,
                localLyrics: vm.localLyricsLibrary,
                onLyricsVisibilityChanged: vm.lyricsCoordinator.refreshVisibility,
                importLocalLyrics: { vm.chooseLocalLyricsFile(from: .settings) },
                lyricsNotice: vm.lyricsNotice?.origin == .settings ? vm.lyricsNotice?.text : nil,
                addLocalLyricsFolder: vm.chooseLocalLyricsFolder,
                removeLocalLyricsFolder: vm.removeLocalLyricsFolder,
                rescanLocalLyrics: vm.rescanLocalLyrics,
                openLocalLyricsFolder: vm.revealLocalLyricsFolder,
                clearImportedLyrics: vm.clearImportedLyrics,
                clearBindingsAndTimingCorrections: vm.clearLyricsBindingsAndTimingCorrections,
                dismissUnassignedLyricsOffset: vm.dismissUnassignedLyricsOffset,
                privacy: vm.privacy,
                wantsKeyboard: $vm.wantsKeyboard,
                setClipboardHistory: vm.setClipboardHistory,
                setClipboardIncludeImages: vm.setClipboardIncludeImages,
                setClipboardKeepPinned: vm.setClipboardKeepPinned,
                refreshClipboardPolling: vm.refreshClipboardPolling,
                setTranslateKeepHistory: vm.setTranslateKeepHistory,
                setTranslateSpeakButton: vm.setTranslateSpeakButton,
                setVolumeAndBrightness: vm.setVolumeAndBrightness,
                accessibilityMissing: vm.accessibilityMissing,
                accessibilityEntrySuspectedStale: vm.accessibilityEntrySuspectedStale,
                accessibilityRepairing: vm.accessibilityRepairing,
                volumeKeysRefused: vm.volumeKeysRefused,
                selection: $vm.settingsSection
            )
        case .welcome:
            WelcomePane(onDismiss: { vm.dismissWelcome() })
        }
    }
}

/// The pages' frame while they travel, and no cut at all at rest: a pane's
/// shadows, its menus' anchors and the cover flying in from the pill are
/// never clipped by it outside a swipe.
private struct PaneClip: Shape {
    var isCutting: Bool

    func path(in rect: CGRect) -> Path {
        Path(isCutting ? rect : rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

/// The island's one accessibility element: a button called Isla. Built by
/// `NotchContentView.islandAccessibility(open:)`, which decides the value, the
/// hint and what a press does; this only says them.
///
/// The children are ignored rather than combined: what the wings draw — a
/// cover, bars, a charge level — is in the value already, and a folded wing is
/// drawn at nothing, so combining would describe a pill that is not there.
private struct IslandAccessibility: ViewModifier {
    let value: String
    let hint: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProductIdentity.displayName)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// The pill's content arriving out of the notch and leaving back into it.
///
/// Blur, scale and opacity together — the way the system's own island
/// dissolves what it shows — rather than a flat fade, on the outline's spring
/// (spec §19.3): from blur 15 and 0.8 of its width, with the shape, and back the
/// same way (`IslandArrival.compact`). The content is pinned to the island's
/// edges (`CompactIslandLayout`), so it travels with them and no edge ever
/// crosses it; only how present it is moves here.
struct PillPresence: ViewModifier {
    let shown: Bool
    let reduceMotion: Bool

    /// How the content looks at either end. Pure, so "folded means nothing
    /// drawn" is a test rather than a hope — `PillFoldTests`.
    nonisolated static func appearance(shown: Bool, reduceMotion: Bool) -> IslandArrival {
        shown ? .arrived() : .compact(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        let look = Self.appearance(shown: shown, reduceMotion: reduceMotion)
        return content.animation(Theme.pill(reduceMotion: reduceMotion)) { view in
            view.modifier(IslandArrivalEffect(look: look))
        }
    }
}

extension View {
    func pillPresence(_ shown: Bool, reduceMotion: Bool) -> some View {
        modifier(PillPresence(shown: shown, reduceMotion: reduceMotion))
    }
}

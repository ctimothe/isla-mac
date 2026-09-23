import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
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

    private var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    private var size: CGSize { vm.bodySize }
    @State private var isPressed = false
    private var compactActivity: CompactMediaActivity { vm.compactMediaActivity }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

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
        !isOpen && !compactActivity.isVisible && vm.geometry.isPhysical
    }

    /// The pointer is on the island, or a press is under way.
    private var isAwake: Bool { vm.isHovering || isPressed }

    /// Hidden at rest, awake under the pointer, and everything else as before.
    private var shapeTopRadius: CGFloat {
        restsInNotch && !isAwake ? 0 : topRadius
    }

    private var shapeBottomRadius: CGFloat {
        if isOpen { return Theme.openBottomRadius }
        if restsInNotch && !isAwake { return Theme.restingNotchBottomRadius }
        return Theme.collapsedBottomRadius
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
            shell
        }
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
        let shown = compactActivity.isVisible
        let notch = vm.geometry.notchSize
        let shape = shown
            ? CGSize(width: size.width + 2 * Theme.collapsedTopRadius, height: notch.height)
            : Self.restingShape(notch: notch)
        return ZStack(alignment: .top) {
            NotchShape(
                topRadius: shown ? Theme.collapsedTopRadius : 0,
                bottomRadius: shown ? Theme.collapsedBottomRadius : Theme.restingNotchBottomRadius
            )
            .fill(Color.black)
            .frame(width: shape.width, height: shape.height)
            // A display with no cutout has nowhere to fold into, so there the
            // shape itself goes; over a real notch it ends inside the hole,
            // where there is no pixel left to hide.
            .opacity(shown || vm.geometry.isPhysical ? 1 : 0)
            // No namespace over the shield, on purpose. This pill and the
            // unlocked one are two branches of `body` that swap in a single
            // transaction, so sharing an identity would hand the lock a
            // travelling cover to interpolate — and the lock is a cut.
            compactMediaHeader(morph: nil)
                // Held inside the wings the way the unlocked shell holds it,
                // so the last blurred trace of the cover can never be drawn on
                // the wallpaper beside a shape that has already moved in.
                .frame(width: size.width, alignment: .center)
                .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // The same lift as unlocked, and the same exclusion: the cutout is a
        // hole and nothing may be drawn in it. Only on a pill that is there.
        .overlay { if shown { hoverLift } }
        .animation(Theme.contentAnimation, value: vm.isHovering)
        // The edge says the island is there; the shake says it is not opening
        // here. Two different answers to two different gestures, rather than
        // one shake for both.
        .contentShape(Rectangle())
        .onTapGesture { vm.onIslandClick?() }
        // Folded, the shape sits one point inside the cutout, and an 11 pt
        // swing would carry ten of them out onto the wallpaper beside it. There
        // is no pill to shake, so nothing shakes.
        .refusalShake(trigger: vm.lockedHoverNudges, amplitude: shown ? RefusalShake.standardAmplitude : 0)
        // Folded, there is nothing here to answer: the notch is only a notch.
        .allowsHitTesting(shown)
        .animation(Theme.pill(appearing: shown, reduceMotion: reduceMotion), value: compactActivity)
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
            .fill(Color.black)
            .frame(width: shapeSize.width, height: shapeSize.height)
            .shadow(
                color: .black.opacity(
                    isOpen ? 0.5 : (compactActivity.isVisible || (restsInNotch && isAwake) ? 0.28 : 0)
                ),
                radius: isOpen ? 18 : 5,
                y: isOpen ? 8 : 2
            )

            // The shape is the only black. A second black layer used to sit
            // over the wings, faded out on its own 0.12 s while the shape
            // contracted — and a removed view keeps the frame it had, so for
            // the first tenth of every fold the pill's full outline stayed on
            // screen, dimming, over a shape already moving in. A fold that
            // begins as a fade is not a fold. Both layers were plain black by
            // then, so the one that could not move is the one that went.

            // Above the shape, never beneath it. Under the old opaque wing
            // layer the only place it showed was the one place it must never
            // show — that layer left the cutout clear, so the lift appeared as
            // a lighter square inside the physical notch and nowhere else.
            // Not while resting in the notch: there the island growing out of
            // the cutout *is* the answer to the pointer, and a lift painted in
            // the old pill's outline would sit on the wrong shape.
            if !isOpen, !restsInNotch { hoverLift }

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
                    // (0.12s), in slower and behind a small delay, so the two
                    // states are never both half-present for long. Applied here
                    // it means the panel has height before the body has alpha,
                    // and on close the body is gone by 0.12s while the panel
                    // still has 0.34s of collapse left to do on its own.
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
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A click anywhere on the collapsed island opens it. The equalizer
        // wing keeps its own tap for play/pause — a child gesture wins, so
        // pausing still costs one click and does not open anything, and the open
        // panel's header strip closes the panel by winning the same way.
        .contentShape(Rectangle())
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
        .animation(Theme.open(reduceMotion: reduceMotion), value: isOpen)
        // The pointer arriving. Over a playing island that is a brightening on
        // a quick ease; over one resting hidden in the notch it is the island
        // growing out of the cutout with a single small bump — see
        // `Theme.hoverNudge`. One curve for both: the brightening has no
        // geometry to overshoot, so the bump only ever shows where it means
        // something.
        .animation(Theme.hoverNudge(reduceMotion: reduceMotion), value: vm.isHovering)
        // Out of the notch and back into it, by direction — see `Theme.pill`.
        // The peek is the same gesture made wider, so it rides the same pair.
        .animation(Theme.pill(appearing: compactActivity.isVisible, reduceMotion: reduceMotion),
                   value: compactActivity)
        .animation(Theme.pill(appearing: vm.isPeeking, reduceMotion: reduceMotion), value: vm.isPeeking)
        .animation(Theme.paneAnimation, value: vm.tab)
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
            compactMediaHeader(morph: morph)
                .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
        }
    }

    private var openHeader: some View {
        HStack(spacing: 0) {
            // Both ends go quiet for the welcome. This row labels the pane below
            // it, and the welcome is not a pane the row can name: it is not a tab
            // (see `NotchViewModel.isShowingWelcome`), and `vm.tab` is left on
            // Music underneath it, so the strip read "MUSIC" over a pane that had
            // nothing to do with Music and the right end named a player for it.
            // The pane carries its own heading; the header has nothing to add for
            // one launch.
            if !vm.isShowingWelcome {
                Text(vm.tab.title.uppercased())
                    .islandFont(.caption, weight: .semibold)
                    .tracking(Theme.capsTracking)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: vm.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if !vm.isShowingWelcome {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: vm.geometry.notchSize.height)
        // Clicking the island again closes the panel, and while the panel is
        // open this strip is all of the island there is: the notch itself, at
        // notch depth, with the body hanging below it. The close cannot be left
        // to the gesture that opens the island — that one's shape is the whole
        // window, so it would turn every click on a control in the panel into a
        // click that shut the panel out from under the control just pressed.
        //
        // Safe to claim the full width because nothing in this row is a control
        // on any tab: the title on the left, and a count or the source name on
        // the right. The rail and the panes begin below it.
        .contentShape(Rectangle())
        .onTapGesture { vm.onIslandClick?() }
    }

    /// - Parameter morph: the namespace the cover and the equalizer travel in,
    ///   or `nil` where there is nowhere for them to travel to — over the lock
    ///   screen, where this pill is the only thing on screen.
    ///
    /// Both wing objects stay laid out while the pill is folded, each centred
    /// in a wing whose width follows the shape. That is what makes a fold read
    /// as the island taking them in: as the wings contract the cover and the
    /// bars travel inward with their edges, and `pillPresence` dissolves them
    /// — blur, scale and fade together — on a curve that finishes before the
    /// edge arrives.
    private func compactMediaHeader(morph: Namespace.ID?) -> some View {
        let wingWidth = max(0, (size.width - vm.geometry.notchSize.width) / 2)
        let shown = compactActivity.isVisible
        return HStack(spacing: 0) {
            // Resting, each wing centres its content the way it always did —
            // pinning to the edges put the artwork and equalizer flush against
            // the pill's rounded ends with no inset at all. Only the peek
            // leads-aligns, because a title reads from the left, and it takes
            // an inset with it so nothing touches the curve.
            HStack(spacing: 7) {
                compactArtwork(morph: morph)
                    .pillPresence(shown, reduceMotion: reduceMotion)
                // Only while peeking, and only on the left wing: the title is
                // what the peek exists to show, and the right wing keeps the
                // equalizer so the pill still says whether audio is moving.
                if vm.isPeeking, let track = vm.media.track {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .islandFont(.caption, weight: .semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .islandFont(.caption, weight: .regular)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    // The title materializes rather than fading flat: the
                    // same blur-and-settle the cover makes arriving. And it
                    // dissolves with the cover when the pill folds — a pause
                    // settling mid-peek used to fold the wing in over a title
                    // still at full strength, slicing it.
                    .pillPresence(shown, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, vm.isPeeking ? 10 : 0)
            .frame(width: wingWidth, alignment: vm.isPeeking ? .leading : .center)

            Color.clear
                .frame(width: vm.geometry.notchSize.width, height: 1)

            compactPlaybackState(morph: morph)
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.trailing, vm.isPeeking ? 12 : 0)
                .frame(width: wingWidth, alignment: vm.isPeeking ? .trailing : .center)
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
        .frame(width: size.width, height: vm.geometry.notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactAccessibilityLabel)
        // Folded, there is nothing on screen to describe.
        .accessibilityHidden(!shown)
        // The same single purpose assistive tech gets: opening. A Pause action
        // here would be a button the compact island does not have, reachable
        // only by people who cannot see that it has none.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard !vm.isLockedPresentation else { return }
            vm.onIslandClick?()
        }
    }

    /// The island brightening under the pointer.
    ///
    /// Built the same way as the wing surface, and for the same reason: on a
    /// Mac with a real notch the middle of this shape is a hole in the display.
    /// Nothing may be drawn there. Lightening it does not lighten the island —
    /// it puts a pale rectangle inside the camera housing, which is the one
    /// place the whole design is trying to make disappear.
    ///
    /// So the lift lands on the wings, which are pixels, and stops at the
    /// cutout, which is not. On a display with no notch there is no hole and
    /// the middle lifts with everything else.
    @ViewBuilder
    private var hoverLift: some View {
        if vm.isHovering || isPressed {
            ZStack {
                liftWings
                // Pressing deepens the same light rather than introducing a
                // second idea: the wings are lit a second time, so the surface
                // catches more of it the harder you are asking. This used to be
                // `.opacity(2.2)` on the one layer, which the compositor clamps
                // to 1 — the press looked exactly like the hover, and the whole
                // press-down path drew nothing.
                if isPressed {
                    liftWings.transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(Theme.contentAnimation, value: isPressed)
            .transition(.opacity)
        }
    }

    /// The lift itself: both wings, faded toward the cutout, clipped to the
    /// collapsed island.
    private var liftWings: some View {
        let wingWidth = max(0, (size.width - vm.geometry.notchSize.width) / 2 + topRadius)
        return HStack(spacing: 0) {
            // Each wing fades out toward the cutout, the way the wing
            // surface underneath already fades into the hardware edge.
            // Without it the two wings lit as hard-edged blocks either side
            // of the notch — two rectangles switching on, rather than light
            // falling across the island.
            Self.liftFill
                .frame(width: wingWidth)
                .mask(Self.falloff(towards: .trailing))
            if vm.geometry.isPhysical {
                Color.clear.frame(width: vm.geometry.notchSize.width)
            } else {
                Self.liftFill.frame(width: vm.geometry.notchSize.width)
            }
            Self.liftFill
                .frame(width: wingWidth)
                .mask(Self.falloff(towards: .leading))
        }
        .frame(width: size.width + 2 * topRadius, height: size.height)
        .clipShape(
            NotchShape(
                topRadius: Theme.collapsedTopRadius,
                bottomRadius: Theme.collapsedBottomRadius
            )
        )
    }

    /// What macOS does when the pointer finds something pressable: lighten the
    /// surface. Weighted to the bottom, furthest from the hardware.
    /// Full strength at the outer edge, gone by the cutout.
    static func falloff(towards edge: UnitPoint) -> LinearGradient {
        LinearGradient(
            colors: [.white, .white.opacity(0.35), .clear],
            startPoint: edge == .trailing ? .leading : .trailing,
            endPoint: edge
        )
    }

    static let liftFill = LinearGradient(
        colors: [.white.opacity(0.015), .white.opacity(0.075)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The near end of the cover's travel.
    ///
    /// It used to be a second cover: 22 pt here, 118 pt in `MediaPane`, each
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
    ///   22 pt in the wing while the cover itself is somewhere between here and
    ///   the panel.
    /// - The image carries no `.transition(.opacity)` of its own any more. A
    ///   travelling object that fades while it travels is a crossfade wearing a
    ///   morph's clothes, and the default transition already crossfades one
    ///   album into the next when the track changes.
    private func compactArtwork(morph: Namespace.ID?) -> some View {
        let metrics = Theme.artworkMetrics(isOpen: false)
        return Color.clear
            .overlay {
                Group {
                    if let artwork = vm.media.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .id(vm.media.track?.key)
                    } else {
                        Image(systemName: "music.note")
                            .islandFont(.caption, weight: .semibold)
                            .foregroundStyle(Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.surface)
                    }
                }
                .opacity(showsPausedCover ? 0.58 : 1)
            }
            .overlay {
                if showsPausedCover {
                    Circle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: 15, height: 15)
                        .overlay(
                            Image(systemName: "play.fill")
                                // A glyph fitted inside a 15pt badge, not type:
                                // the caption floor would burst the circle.
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .offset(x: 0.5)
                        )
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
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

    /// The equalizer travels too, and it is the easier half: both ends are the
    /// same 10 pt box, so the effect only has to carry it from the pill's right
    /// wing to the open header's right end. Without it the bars vanished on one
    /// side of the notch and reappeared on the other, which reads as two
    /// equalizers for one piece of music.
    private func compactPlaybackState(morph: Namespace.ID?) -> some View {
        EqualizerBars(
            isAnimating: compactActivity.animatesEqualizer,
            opacity: compactActivity == .playing ? 0.82 : 0.58
        )
        .morph(MorphID.compact(MorphID.equalizer, folded: !compactActivity.isVisible), in: morph)
    }

    private var compactAccessibilityLabel: String {
        guard let track = vm.media.track else { return "" }
        let state = compactActivity == .playing ? localized("Playing") : localized("Paused")
        return "\(state): \(track.title), \(track.artist)"
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    // The far end of the equalizer's travel — the same bars that
                    // were in the pill's right wing a moment ago, not a second
                    // set switched on in their place.
                    //
                    // The compact end answers to this name only while the pill
                    // shows (`MorphID.compact`); this end additionally needs a
                    // track, the Media tab and no welcome pane, so the pair can
                    // be half-present — open the panel on Shelf and only the
                    // pill's bars exist. That is safe rather than accidental:
                    // both ends are sources, so a lone member plays its own
                    // transition instead of collapsing onto a frame that is not
                    // there.
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                        .morph(MorphID.equalizer, in: morph)
                }
                Text(vm.media.sourceName ?? "")
                    .islandFont(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, tabs: NotchViewModel.Tab.contentTabs, footer: NotchViewModel.Tab.utilityTabs)
            panes
        }
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            // For one launch, the welcome wins over the tab. Here rather than
            // inside `pane` so the per-tab switch and its transitions are
            // untouched, and so the rail — which the welcome's last line points
            // at — stays exactly where it is. A plain crossfade, because
            // dismissing it is not travel between two tabs: one thing ends and
            // the panel it was in carries on.
            if vm.isShowingWelcome {
                WelcomePane(onDismiss: { vm.dismissWelcome() })
                    .transition(.opacity)
            } else {
                pane
                    .id(vm.tab)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.97))
                            .animation(Theme.paneIn),
                        removal: .opacity
                            .combined(with: .scale(scale: 1.02))
                            .animation(Theme.paneOut)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            // The namespace goes down with the pane: the far end of the cover's
            // travel is drawn inside it, and it is the one pane that has an end
            // to offer. Open on any other tab and the compact cover is simply a
            // lone member of the group — it leaves the way it always did.
            MediaPane(
                media: vm.media,
                lyrics: vm.lyrics,
                localLookup: vm.lyricsCoordinator.localLookup,
                retryLyrics: vm.lyricsCoordinator.retry,
                importLocalFile: vm.chooseLocalLyricsFile,
                selectLocalCandidate: vm.lyricsCoordinator.selectLocalCandidate,
                removeLocalBinding: vm.lyricsCoordinator.removeLocalBinding,
                localLibrary: vm.localLyricsLibrary,
                currentLocalTrackIdentity: { vm.lyricsCoordinator.currentLocalTrackIdentity },
                morph: morph,
                showingLyrics: $vm.isShowingLyrics
            )
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .translate:
            TranslatePane(translator: vm.translator, privacy: vm.privacy, wantsKeyboard: $vm.wantsKeyboard)
        case .settings:
            SettingsPane(
                shelf: vm.shelf,
                screenshotVault: vm.screenshotVault,
                lyrics: vm.lyrics,
                localLyrics: vm.localLyricsLibrary,
                onLyricsVisibilityChanged: vm.lyricsCoordinator.refreshVisibility,
                importLocalLyrics: vm.chooseLocalLyricsFile,
                addLocalLyricsFolder: vm.chooseLocalLyricsFolder,
                removeLocalLyricsFolder: vm.removeLocalLyricsFolder,
                rescanLocalLyrics: vm.rescanLocalLyrics,
                openLocalLyricsFolder: vm.revealLocalLyricsFolder,
                clearImportedLyrics: vm.clearImportedLyrics,
                clearBindingsAndTimingCorrections: vm.clearLyricsBindingsAndTimingCorrections,
                dismissUnassignedLyricsOffset: vm.dismissUnassignedLyricsOffset,
                privacy: vm.privacy,
                wantsKeyboard: $vm.wantsKeyboard
            )
        }
    }
}

/// Tab switcher.
///
/// A click changes the tab, and nothing else does. Hovering used to switch
/// after a 150 ms dwell, which made the rail react to a pointer passing
/// through it: moving across it on the way somewhere flipped panes, and each
/// flip replayed the chosen glyph's fill, so a fast pass read as the rail
/// stuttering behind the cursor (owner, 2026-09-21). macOS does not navigate
/// on hover outside menus; a sidebar changes when it is clicked.
///
/// A hover draws a faint well under the glyph and nothing more, and both the
/// well and the selection land on the frame they happen — no fade to wait
/// out, no glyph growing, nothing to lag behind a fast pointer.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    /// The run of content tabs people move between.
    let tabs: [NotchViewModel.Tab]
    /// Held to the bottom of the rail, below the gap: settings, which nobody
    /// should have to hover past on the way to a track.
    var footer: [NotchViewModel.Tab] = []

    @State private var hovered: NotchViewModel.Tab?

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { icon(for: $0) }
            if !footer.isEmpty {
                Spacer(minLength: 10)
                ForEach(footer) { icon(for: $0) }
            }
        }
        .frame(width: 30)
        // The rail owns the body's full content height: the run of tabs at the
        // top, settings held to the bottom by the gap between them.
        .frame(height: vm.geometry.standardContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func icon(for tab: NotchViewModel.Tab) -> some View {
        Button {
            // `chooseTab`, not `select`: this is the one place a *person* picks
            // a tab, and picking one is also how somebody answers the welcome
            // with "not this, that" instead of pressing Get Started.
            vm.chooseTab(tab)
        } label: {
            Image(systemName: tab.symbol)
                // Filled when chosen, outlined otherwise — the tab bar's own
                // grammar — swapped on the frame of the click. The note and the
                // sliders have no filled form, so for Music and Settings the
                // chip alone says which is chosen. The system's
                // replace effect was tried and withdrawn the same day: it takes
                // a third of a second, and a rail that answers a click a third
                // of a second late reads as a rail catching up.
                .symbolVariant(vm.tab == tab ? .fill : .none)
                .islandFont(.subhead)
                .frame(width: 30, height: vm.geometry.railIconHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill(for: tab))
                )
                .overlay(
                    // The selected chip's own edge, following `ShelfPane`'s
                    // selected tile: a fill plus a 1.5pt border, rather than
                    // the borrowed `surfaceHover` that made selected and
                    // hovered the same colour with no edge on either.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            Theme.selectedChipBorder.opacity(vm.tab == tab ? 1 : 0),
                            lineWidth: 1.5
                        )
                        .allowsHitTesting(false)
                )
                .foregroundStyle(vm.tab == tab ? Color.white : Theme.tertiary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // Nothing the shell animates reaches the glyph and its well: the
                // pane change rides the shell's pane curve, and this would
                // otherwise fade the chip along with it. The press dim is the
                // button style's own and still answers on press-down.
                .transaction { $0.animation = nil }
        }
        .buttonStyle(PanelButtonStyle())
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(vm.tab == tab ? [.isButton, .isSelected] : .isButton)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
    }

    @MainActor
    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.selectedChip }
        return hovered == tab ? Theme.surface : .clear
    }
}

/// The pill's content arriving out of the notch and leaving back into it.
///
/// Blur, scale and opacity together — the way the system's own island
/// dissolves what it shows — rather than a flat fade, and on a curve of its
/// own (`Theme.pillContent`), scoped to these three effects. The frame the
/// content sits in is left to the shape's spring; only how present it is
/// moves on this one, which is what lets the content leave ahead of the edge.
struct PillPresence: ViewModifier {
    let shown: Bool
    let reduceMotion: Bool

    /// How the content looks at either end. Pure, so "folded means nothing
    /// drawn" is a test rather than a hope — `PillFoldTests`.
    struct Appearance: Equatable {
        var blur: CGFloat
        var scale: CGFloat
        var opacity: Double
    }

    nonisolated static func appearance(shown: Bool, reduceMotion: Bool) -> Appearance {
        if shown { return Appearance(blur: 0, scale: 1, opacity: 1) }
        // Reduce Motion keeps the change and drops the travel: a fade, with no
        // shrinking and no softening.
        return reduceMotion
            ? Appearance(blur: 0, scale: 1, opacity: 0)
            : Appearance(blur: 5, scale: 0.72, opacity: 0)
    }

    func body(content: Content) -> some View {
        let look = Self.appearance(shown: shown, reduceMotion: reduceMotion)
        return content.animation(Theme.pillContent(shown: shown, reduceMotion: reduceMotion)) { view in
            view
                .blur(radius: look.blur)
                .scaleEffect(look.scale)
                .opacity(look.opacity)
        }
    }
}

extension View {
    func pillPresence(_ shown: Bool, reduceMotion: Bool) -> some View {
        modifier(PillPresence(shown: shown, reduceMotion: reduceMotion))
    }
}

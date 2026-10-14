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
    /// Whether the collapsed pill is out of the notch: music, or the charger
    /// or headphones having their moment.
    private var pillShown: Bool { compactActivity.isVisible || vm.ambient != nil }
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
        !isOpen && !pillShown && vm.geometry.isPhysical
    }

    /// The pointer is on the island, or a press is under way.
    private var isAwake: Bool { vm.isHovering || isPressed }

    /// Hidden at rest, awake under the pointer, and everything else as before.
    private var shapeTopRadius: CGFloat {
        restsInNotch && !isAwake ? 0 : topRadius
    }

    private var shapeBottomRadius: CGFloat {
        // 22 on the standard body, 26 on the tall one (spec §2.3); the shape
        // animates its radii, so it springs 22 → 26 with the body's height.
        if isOpen { return Theme.openBottomRadius(tall: vm.isCurrentTabExpanded) }
        if restsInNotch && !isAwake { return Theme.restingNotchBottomRadius }
        // The peek is a taller island, and its corners grow with it (spec
        // §2.3): 16 against the compact island's 12.
        if vm.isPeeking && compactActivity.isVisible { return Theme.peekBottomRadius }
        return Theme.collapsedBottomRadius
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

    // MARK: - Key line (spec §3.3)

    /// Whether the island has a key line to draw: it must be showing
    /// something — the pill out of the notch, or the panel open; a resting
    /// notch is the notch — and the wallpaper dark, or Increase Contrast on.
    private var keyLineShown: Bool {
        guard isOpen || pillShown else { return false }
        return KeyLine.isShown(tone: vm.wallpaper.reading, increaseContrast: appearance.increaseContrast)
    }

    /// Music while the island or panel shows a song, neutral for anything else.
    private var keyLineColor: Color {
        let style = KeyLine.style(
            isOpen: isOpen,
            onMusicTab: vm.tab == .media && !vm.isShowingWelcome,
            hasTrack: vm.media.track != nil,
            pillShowsMusic: compactActivity.isVisible,
            momentShowing: vm.ambient != nil
        )
        return KeyLine.color(for: style, tint: vm.coverTint)
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
            .fill(shown && vm.isHovering ? Theme.islandHover : Color.black)
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
                // The refusal under Reduce Motion: the content dips, the black
                // shape above stays put (see `RefusalShake`).
                .refusalContentDim()
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
        // The edge says the island is there; the shake says it is not opening
        // here. Two different answers to two different gestures, rather than
        // one shake for both.
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
            // Under the black, where only the outer half of a stroke twice the
            // width wanted shows: that is what makes it "just outside" the
            // island. Always mounted and faded, never inserted, so it folds
            // and unfolds with the shape instead of arriving after it. Open,
            // the same line follows the body's height as it springs, because
            // it is built from the same radii and the same frame.
            KeyLineShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
                .stroke(keyLineColor, lineWidth: 2 * Theme.keyLineWidth)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .opacity(keyLineShown ? 1 : 0)
                .allowsHitTesting(false)

            NotchShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
            .fill(shapeFill)
            .frame(width: shapeSize.width, height: shapeSize.height)
            .shadow(
                color: .black.opacity(
                    isOpen ? 0.5 : (pillShown || (restsInNotch && isAwake) ? 0.28 : 0)
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
            .clipped()
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
        // Out of the notch and back into it, by direction — see `Theme.pill`.
        // The peek is the same gesture made wider, so it rides the same pair.
        .animation(Theme.pill(appearing: compactActivity.isVisible, reduceMotion: reduceMotion),
                   value: compactActivity)
        .animation(Theme.pill(appearing: vm.isPeeking, reduceMotion: reduceMotion), value: vm.isPeeking)
        .animation(Theme.pill(appearing: vm.ambient != nil, reduceMotion: reduceMotion), value: vm.ambient)
        .animation(Theme.paneAnimation, value: vm.tab)
        // The body growing or folding (spec §6): its height, its bottom radius
        // and — through the same value — the key line that follows them, on the
        // expand spring, or the 0.24 crossfade under Reduce Motion. Keyed to the
        // *open* body's height, which opening and closing do not change, so this
        // never answers the open spring's own change of size.
        .animation(Theme.expand(reduceMotion: reduceMotion), value: vm.openBodySize.height)
        // The welcome ending is a pane change like any other, and it arrives
        // from a `Button` — which animates nothing by itself, so without this
        // the crossfade above would be a cut.
        .animation(Theme.paneAnimation, value: vm.isShowingWelcome)
        // The island asking the wallpaper again as it unfolds, from the notch
        // or open (spec §3.3): a Space change or a wake would have said so, and
        // this catches whatever did not. A cache hit costs nothing.
        .onChange(of: pillShown) { _, shown in if shown { vm.wallpaper.refresh() } }
        .onChange(of: isOpen) { _, open in if open { vm.wallpaper.refresh() } }
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
                    .opacity(vm.ambient == nil ? 1 : 0)
                if let ambient = vm.ambient {
                    ambientHeader(ambient)
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                }
            }
            // The island to assistive tech, on the stack that holds both the
            // music and the moment, so that a peek or a charger changes this
            // element's value rather than swapping one element for another.
            .modifier(islandAccessibility(open: false))
            .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
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
        if !vm.isLockedPresentation, let ambient = vm.ambient { return ambient.accessibilityLabel }
        return vm.media.track == nil ? localized("Nothing is playing.") : compactAccessibilityLabel
    }

    /// The open island's value: what the header strip shows — the tab, and
    /// the count or the player on its right end. The welcome is not a tab
    /// (see `openHeader`), so there it names the welcome instead.
    private var openIslandValue: String {
        if vm.isShowingWelcome { return localized("Welcome") }
        let detail: String?
        switch vm.tab {
        case .media: detail = vm.media.sourceName
        case .shelf: detail = vm.shelf.items.isEmpty ? nil : "\(vm.shelf.items.count)"
        case .clipboard: detail = vm.clipboard.items.isEmpty ? nil : "\(vm.clipboard.items.count)"
        case .translate, .settings: detail = nil
        }
        guard let detail, !detail.isEmpty else { return vm.tab.title }
        return "\(vm.tab.title), \(detail)"
    }

    /// The charger or headphones, in the pill's two wings (spec §3.6).
    ///
    /// One grammar for both: a glyph in the left wing where the cover sits,
    /// and what it is about in the right wing where the equalizer sits. Laid on
    /// the same margins as the music island — 8 from either edge — so a moment
    /// arriving over a song moves nothing but what it says.
    ///
    /// Charging is green, as the system draws a charging battery: the bolt and
    /// its level, at 13 pt and 12 pt. A Mac with no battery reports no level and
    /// gets a white bolt alone; the plug that says a battery is holding is white
    /// too, because green is "charging" and a held charge is not. Headphones are
    /// white, the device's own symbol at left and its name at right, truncating
    /// at the tail — never into the camera. "Connected" is left to the
    /// accessibility label: the glyph arriving already says it.
    private func ambientHeader(_ ambient: AmbientActivity) -> some View {
        let wing = max(0, (size.width - vm.geometry.notchSize.width) / 2)
        let symbol: String
        let value: String?
        let boxWidth: CGFloat
        switch ambient {
        case .charging(let level, _):
            symbol = ambient.chargeSymbol
            value = level.map { localized("%d%%", $0) }
            boxWidth = CompactIslandLayout.chargeLevelWidth
        case .headphones(let name, let deviceSymbol):
            symbol = deviceSymbol
            value = name
            boxWidth = CompactIslandLayout.deviceNameWidth(wing: wing)
        }
        let tone: Color = ambient.usesChargingGreen ? Theme.chargingGreen : .white
        return HStack(spacing: 0) {
            Image(systemName: symbol)
                .islandFont(.subhead, weight: .semibold)
                .foregroundStyle(tone)
                // Centred on the cover's own column — 20 from the edge — so the
                // glyph takes the cover's place rather than sitting beside it.
                .frame(width: CompactIslandLayout.coverSide, height: CompactIslandLayout.coverSide)
                .padding(.leading, NotchMetrics.compactEdgeInset)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .font(Theme.TypeRole.reading.font(weight: .semibold).monospacedDigit())
                    .foregroundStyle(tone)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: boxWidth, alignment: .trailing)
                    .padding(.trailing, NotchMetrics.compactEdgeInset)
            }
        }
        .frame(width: size.width, height: size.height)
        // No element of its own: the moment is the island's value, set on the
        // stack above it — see `islandAccessibility(open:)`.
    }

    private var openHeader: some View {
        headerRow
            // The same close for assistive tech, as the same Isla button the shut
            // island is — the gesture above has no trait and no action, so a panel
            // opened from VoiceOver had no discoverable way to close (G-015).
            .modifier(islandAccessibility(open: true))
            // The lyric page's tools (spec §5.2) are laid over the strip *after*
            // the accessibility element above, which ignores its children: put
            // inside, the three buttons would be unreachable to VoiceOver. Each
            // is placed by its own offset, so the rest of the strip keeps its
            // click-to-close.
            .modifier(LyricHeaderTools(
                isShown: showsLyricTools,
                bodyWidth: size.width,
                showsTranslation: vm.showsTranslationTool,
                translationShown: vm.translation.isShown,
                toggleTranslation: { vm.translation.toggleShown() },
                translateController: vm.lyricsTranslateMenu,
                moreController: vm.lyricsMoreMenu,
                isExpanded: Binding(
                    get: { vm.expandedTabs.contains(.media) },
                    set: { wants in
                        withAnimation(Theme.expand(reduceMotion: reduceMotion)) {
                            vm.setExpanded(wants, for: .media)
                        }
                    }
                )
            ))
    }

    /// Whether the header carries the lyric tools: the Music tab on the column
    /// or the tall page, and not the welcome (which owns the pane for one launch).
    private var showsLyricTools: Bool {
        !vm.isShowingWelcome && vm.tab == .media && vm.musicPage != .player
    }

    private var headerRow: some View {
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
                .padding(.leading, NotchMetrics.compactEdgeInset)
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
                .padding(.trailing, NotchMetrics.compactEdgeInset)
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
        // 24 pt at radius 6 resting, 34 at 8 while a track peeks: one cover in
        // two sizes, and the frame interpolates between them on the same curve
        // the island grows on.
        let metrics = vm.isPeeking && compactActivity.isVisible
            ? Theme.peekArtworkMetrics
            : Theme.artworkMetrics(isOpen: false)
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
    /// Four bars in the cover's tint while music plays; at rest, 3 pt tall in
    /// tertiary, when it is paused (spec §3.2).
    private func compactPlaybackState(morph: Namespace.ID?) -> some View {
        CompactEqualizer(
            isAnimating: compactActivity.animatesEqualizer,
            color: CompactEqualizerMotion.color(
                isPlaying: compactActivity.tintsEqualizer,
                tint: vm.coverTint,
                increaseContrast: appearance.increaseContrast
            )
        )
        .morph(MorphID.compact(MorphID.equalizer, folded: !compactActivity.isVisible), in: morph)
    }

    /// The view model's, because the peek announces the same sentence.
    private var compactAccessibilityLabel: String { vm.compactAccessibilityLabel }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            // The source tag (spec §4.1): the equalizer, then the player's own
            // icon — Music's, Spotify's — in place of a second "Music" in words
            // beside the tab's title. The bars end 8 pt before the icon, which
            // is 18 pt and ends 17 from the body's edge; the strip's own 16 pt
            // padding plus the 1 pt below is that 17.
            HStack(spacing: 8) {
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
                    //
                    // The same four-bar view as the island's, in the cover's tint
                    // while the music plays and at rest, tertiary, when it does
                    // not (spec §3.2): one equalizer, drawn in both places.
                    CompactEqualizer(
                        isAnimating: vm.media.isPlaying,
                        color: CompactEqualizerMotion.color(
                            isPlaying: vm.media.isPlaying,
                            tint: vm.coverTint,
                            increaseContrast: appearance.increaseContrast
                        )
                    )
                    .morph(MorphID.equalizer, in: travellingMorph)
                    if let icon = vm.media.sourceIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: Self.sourceIconSide, height: Self.sourceIconSide)
                            .padding(.trailing, 1)
                            .accessibilityLabel(vm.media.sourceName ?? "")
                    }
                }
            }
            // The lyric column and the tall page put their own tools where the
            // source tag is (spec §5.1: `src` is hidden in C and T), so it gives
            // the corner up rather than sit under them.
            .opacity(vm.musicPage == .player ? 1 : 0)
            .accessibilityHidden(vm.musicPage != .player)
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(Self.clipboardCounter(
                count: vm.clipboard.items.count, covered: vm.privacy.covers(.clipboard)
            ) ?? 0)
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .settings:
            EmptyView()
        }
    }

    /// The player's app icon in the header's source tag: 18 pt square
    /// (spec §4.1).
    static let sourceIconSide: CGFloat = 18

    /// The number the clipboard header shows, or nil for none. With the cover
    /// on, the header read "6" over rows of dots, and a screen-share audience
    /// learned how many things had been copied (H-026). Pure, so it is a test.
    static func clipboardCounter(count: Int, covered: Bool) -> Int? {
        covered || count <= 0 ? nil : count
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
        HStack(spacing: PlayerLayout.railGap) {
            Rail(vm: vm, tabs: NotchViewModel.Tab.contentTabs, footer: NotchViewModel.Tab.utilityTabs)
            panes
        }
        // The pane starts at `PlayerLayout.paneLeading` = this padding + the
        // rail + the gap; the player's board is measured from there.
        .padding(.horizontal, PlayerLayout.bodyInset)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // VO-Escape, or Switch Control's Escape, anywhere in the body closes
        // the panel, as the header does. A panel opened from assistive tech is
        // pinned open, and the pin ends only on a real mouse-down in another
        // app, so without this the only way out was the global hot key —
        // which someone who opened Isla by its button may not know (G-015).
        .accessibilityAction(.escape) { vm.onIslandClick?() }
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            // For one launch, the welcome wins over the tab. Here rather than
            // inside `pane` so the per-tab switch and its transitions are
            // untouched, and so the rail — whose icons the welcome's legends sit
            // level with, one line each, which is why its icon height goes
            // down too — stays exactly where it is. A plain crossfade, because
            // dismissing it is not travel between two tabs: one thing ends and
            // the panel it was in carries on.
            if vm.isShowingWelcome {
                WelcomePane(onDismiss: { vm.dismissWelcome() }, railIconHeight: vm.geometry.railIconHeight)
                    .transition(.opacity)
            } else {
                // The slight zoom is the only travel a swap has, and Reduce
                // Motion takes it: the scales come from the theme, 1 under
                // the setting, so the swap is a plain crossfade (F-017).
                let scales = Theme.paneSwapScales(reduceMotion: reduceMotion)
                pane
                    .id(vm.tab)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: scales.insertion))
                            .animation(Theme.paneIn),
                        removal: .opacity
                            .combined(with: .scale(scale: scales.removal))
                            .animation(Theme.paneOut)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // One group, named for what it holds. Loose, the pane's elements were
        // read in among the rail's by position — the Translate tab put
        // "Translate From" between Music and Shelf.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(vm.isShowingWelcome ? localized("Welcome") : vm.tab.title)
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
                turnOnLyrics: vm.turnOnLyrics,
                turnOnOnlineLyrics: vm.turnOnOnlineLyrics,
                importLocalFile: { vm.chooseLocalLyricsFile(from: .stage) },
                lyricsNotice: vm.lyricsNotice?.origin == .stage ? vm.lyricsNotice?.text : nil,
                selectLocalCandidate: vm.lyricsCoordinator.selectLocalCandidate,
                removeLocalBinding: vm.lyricsCoordinator.removeLocalBinding,
                localLibrary: vm.localLyricsLibrary,
                currentLocalTrackIdentity: { vm.lyricsCoordinator.currentLocalTrackIdentity },
                invalidLine: {
                    vm.lyricsCoordinator.currentLocalTrackIdentity.flatMap { vm.localLyricsLibrary.invalidLine(for: $0) }
                },
                isExpanded: vm.expandedTabs.contains(.media),
                editingSession: $vm.lyricEditing,
                openMusicOnlySetting: vm.openMusicOnlySetting,
                morph: travellingMorph,
                showingLyrics: $vm.isShowingLyrics,
                headerHeight: vm.geometry.notchSize.height,
                audio: vm.playerAudio,
                translation: vm.translation
            )
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(
                clipboard: vm.clipboard, privacy: vm.privacy,
                turnOnHistory: { vm.setClipboardHistory(true) }
            )
        case .translate:
            TranslatePane(translator: vm.translator, privacy: vm.privacy, wantsKeyboard: $vm.wantsKeyboard)
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
                refreshClipboardPolling: vm.refreshClipboardPolling,
                scrollTarget: $vm.settingsScrollTarget
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
///
/// Internal rather than private for two readers: `WelcomePane`, whose legend
/// column keeps this rail's rhythm, and the test that holds `isLit`.
struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    /// The run of content tabs people move between.
    let tabs: [NotchViewModel.Tab]
    /// Held to the bottom of the rail, below the gap: settings, which nobody
    /// should have to hover past on the way to a track.
    var footer: [NotchViewModel.Tab] = []

    @State private var hovered: NotchViewModel.Tab?

    /// The least room between the run of content tabs and Settings below it.
    /// `WelcomePane` holds its Settings legend down with the same gap, so the
    /// line stays level with the icon on a body that leaves no more than this.
    static let footerGap: CGFloat = 10

    /// Whether `tab`'s chip is drawn chosen — its fill, its filled glyph, its
    /// edge — and carries the selected trait.
    ///
    /// Not while the welcome is up. The model leaves `tab` on Music underneath
    /// it, so that Get Started lands there, and the chip used to follow `tab`
    /// alone: the rail lit Music over a pane that was not Music, and VoiceOver
    /// said "Music, selected" on the welcome (H-020). The welcome is not a tab,
    /// so no tab is chosen while it shows.
    static func isLit(_ tab: NotchViewModel.Tab, selected: NotchViewModel.Tab, welcoming: Bool) -> Bool {
        !welcoming && tab == selected
    }

    private func isLit(_ tab: NotchViewModel.Tab) -> Bool {
        Self.isLit(tab, selected: vm.tab, welcoming: vm.isShowingWelcome)
    }

    /// Read for one thing: whether Settings wears the mark that says a newer
    /// Isla is out. Set only by a check the user ran or turned on.
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { icon(for: $0) }
            if !footer.isEmpty {
                Spacer(minLength: Self.footerGap)
                ForEach(footer) { icon(for: $0) }
            }
        }
        .frame(width: PlayerLayout.railWidth)
        // The rail owns the body's full content height: the run of tabs at the
        // top, settings held to the bottom by the gap between them.
        // The open body's, not the standard one's: on the tall body (spec §6)
        // the top items stay put and Settings rides the foot.
        .frame(height: vm.geometry.contentHeight(forBodyHeight: vm.openBodySize.height), alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        // The five tabs together, under one name, and apart from the pane —
        // see the pane's own group in `NotchContentView.panes`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Tabs"))
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
                .symbolVariant(isLit(tab) ? .fill : .none)
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
                            Theme.selectedChipBorder.opacity(isLit(tab) ? 1 : 0),
                            lineWidth: 1.5
                        )
                        .allowsHitTesting(false)
                )
                .foregroundStyle(isLit(tab) ? Color.white : Theme.tertiary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // Nothing the shell animates reaches the glyph and its well: the
                // pane change rides the shell's pane curve, and this would
                // otherwise fade the chip along with it. The press dim is the
                // button style's own and still answers on press-down.
                .transaction { $0.animation = nil }
        }
        .buttonStyle(PanelButtonStyle())
        .overlay(alignment: .topTrailing) {
            // The app's badge, one primitive for two reasons: a newer version,
            // found by a check the user asked for, and a screenshot that
            // arrived while another tab was showing (it used to switch the tab
            // under the user). A dot rather than a count, in the chrome's own
            // white. It says "look here", and the pane says what.
            if hasBadge(tab) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .offset(x: -3, y: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(badgeValue(tab))
        .accessibilityAddTraits(isLit(tab) ? [.isButton, .isSelected] : .isButton)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
    }

    @MainActor
    private func hasBadge(_ tab: NotchViewModel.Tab) -> Bool {
        switch tab {
        case .settings: return updates.hasUpdate
        case .shelf: return vm.shelfHasNew
        default: return false
        }
    }

    @MainActor
    private func badgeValue(_ tab: NotchViewModel.Tab) -> String {
        guard hasBadge(tab) else { return "" }
        return tab == .shelf ? localized("New screenshot") : localized("Update available")
    }

    @MainActor
    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if isLit(tab) { return Theme.selectedChip }
        return hovered == tab ? Theme.surface : .clear
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

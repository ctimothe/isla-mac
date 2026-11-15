import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// The pages on their way between two (spec §19.16): watched here, where
    /// the outline and the pages are drawn from it, and nowhere else.
    @ObservedObject private var travel: PageTravel
    /// The vertical pull's give (`IslandPull`): watched here, where the
    /// outline is drawn, and nowhere else.
    @ObservedObject var pull: IslandPullStretch
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
    @ObservedObject var appearance = SystemAppearance.shared
    var reduceMotion: Bool { appearance.reduceMotion }
    /// The update badge on Tools' Settings, and the shortcuts Tools' cards
    /// name: both follow their sources while the panel is up.
    @ObservedObject var updates = UpdateCheck.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    /// The Core Animation outline the panel draws the island's shape with
    /// (`NotchStage`, spec §19.12), or none. With one, this view draws no fill,
    /// no shadow, no mask and no line of its own: it only says what the outline
    /// is (`outlineState`) and on which transaction it changes, and the layers
    /// do the moving off the main thread. Without one — a preview, a test, the
    /// visual lab — it draws all of it in SwiftUI, as it did before, and the
    /// equivalence tests hold the two to one picture.
    let outline: IslandOutlineHost?

    init(vm: NotchViewModel, outline: IslandOutlineHost? = nil) {
        _vm = ObservedObject(wrappedValue: vm)
        _travel = ObservedObject(wrappedValue: vm.pageTravel)
        _pull = ObservedObject(wrappedValue: vm.pullStretch)
        self.outline = outline
        // A shell built over a panel that is already open — an unlock, a
        // display change, a test's snapshot — has no open to stage.
        _bodyStaged = State(initialValue: vm.isOpen || vm.isDropTargeted)
    }

    /// Translate's History is offered only while Keep History is on (spec
    /// §11): read from the translator's own defaults when the header draws,
    /// which every surface change does.
    var translateKeepsHistory: Bool {
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
    var travellingMorph: Namespace.ID? {
        Self.travels(reduceMotion: reduceMotion) ? morph : nil
    }

    var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    var size: CGSize { vm.bodySize }
    @State var isPressed = false

    /// Whether the open body may mount its content (MR-H18, 2026-10-26).
    ///
    /// The open's first frame used to mount the whole surface beside the
    /// outline's change, and the hitch lab put the cost there: 8.4 + 8.2 +
    /// 4.6 ms of main thread in the first three 8.3 ms frames opening the
    /// lyric stage, 6.8 ms in the first opening the tray, against about 1 ms
    /// a frame for the rest of the spring — every missed frame of an open was
    /// in its first 100 ms. The outline's spring is committed to Core
    /// Animation in that same frame, so a frame the mount made late was a
    /// frame the island did not start moving in.
    ///
    /// So the open's first frame carries the outline and the header alone, and
    /// the body mounts one run-loop pass later, in a commit of its own: by
    /// then the outline is moving in the render server, and a heavy commit no
    /// longer holds it. Nothing is seen to wait — the body fades in behind
    /// `Theme.paneIn`'s 40 ms delay either way. Not the player while the
    /// cover travels: its far end is inside `MediaPane`, and a morph's two
    /// ends must be in the tree in the same transaction (`MorphID`). The
    /// player stages itself instead, by the same flag: the cover and the
    /// equalizer in the outline's frame, the rest a pass later
    /// (`MediaPane.holdsBackRest`).
    @State var bodyStaged = false

    /// Whether opening onto `surface` mounts its content a pass after the
    /// outline starts (`bodyStaged`). Pure, for `NotchContentStagingTests`.
    nonisolated static func stagesBody(opening surface: NotchViewModel.Surface, reduceMotion: Bool) -> Bool {
        surface != .player || !travels(reduceMotion: reduceMotion)
    }

    /// The open body is in the tree.
    var bodyShown: Bool {
        isOpen && (bodyStaged || !Self.stagesBody(opening: vm.presented, reduceMotion: reduceMotion))
    }
    var compactActivity: CompactMediaActivity { vm.compactMediaActivity }
    /// Whether the collapsed pill is out of the notch: any activity at all —
    /// an alert, the song, or the Shelf holding files (`IslandActivity`).
    var pillShown: Bool { vm.activity != .none }
    /// The shoulder: the open panel's, or what the shut island shows —
    /// an expanded alert's are wider than a compact activity's
    /// (`IslandShapeRadii`).
    var topRadius: CGFloat { isOpen ? vm.openTopRadius : vm.closedTopRadius }

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
                // With the outline on Core Animation the island's content is
                // cut by its mask, and the bubble lives outside the outline:
                // it is drawn by a hosting view of its own, above this one
                // (`IslandBubbleLayer`, `NotchStage`).
                if outline == nil {
                    IslandBubbleLayer(vm: vm)
                    HUDStripLayer(vm: vm)
                }
            }
        }
    }
}

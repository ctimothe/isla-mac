import AppKit

/// Drives hover state by sampling the pointer position on a timer.
///
/// Event monitors are not usable here. A global `NSEvent` monitor never sees
/// events delivered to this app's own windows, and a local monitor only fires
/// while the app is active — which an `.accessory` app never is. That makes
/// hover depend on which window happens to sit under the pointer. Sampling
/// `NSEvent.mouseLocation` is independent of event routing, so it behaves
/// identically everywhere, at the cost of one cursor-position read per frame.
@MainActor
final class PointerWatcher {
    /// Entering this opens the panel, in screen coordinates.
    var openRect: CGRect = .zero
    /// Leaving this closes the panel, in screen coordinates.
    var closeRect: CGRect = .zero {
        didSet {
            guard closeRect != oldValue else { return }
            noteShrink(from: oldValue)
        }
    }
    /// Where the panel takes clicks. Everywhere else the window must let them
    /// through, so this doubles as the `ignoresMouseEvents` trigger.
    var interactiveRect: CGRect = .zero
    /// The Shelf's bubble, which takes clicks too while it shows (spec §19.7),
    /// and only it: the gap between it and the island stays click-through.
    var bubbleRect: CGRect = .zero

    /// The collapsed island the panel was opened from, counted as part of
    /// `closeRect` — while the panel is open — until the pointer has once
    /// stood on the open body.
    ///
    /// Since R8 each surface has its own width, and two things that open one
    /// are wider than it: the new-track peek, notch + 300 (spec §3.5), opens
    /// the 357.4 pt player, and the far end of the Shelf's bubble sits past the
    /// tray's edge under a 200 pt notch. A pointer that opened the panel from
    /// there stood outside the body it had opened, so the panel folded
    /// `closeDelay` later — and with Open on Hover on, the island under the
    /// same pointer opened it again, round and round (R8 review F1).
    ///
    /// Captured whenever the pointer is counted inside a closed panel — a
    /// click, an arrival — but honoured only while the panel is open: with
    /// Open on Hover off an arrival opens nothing, and a landing honoured on
    /// a closed panel kept a pointer resting on bare menu bar "inside" after
    /// the peek it arrived on had folded, refusing every later peek and
    /// moment (R8 re-review R-1). Reaching the body, leaving, or a forced
    /// "outside" lets it go.
    private(set) var landingRect: CGRect = .zero

    /// The open body the panel shrank out of, while the pointer that was on it
    /// stays in it and has not gone anywhere: counted as part of `closeRect`
    /// until the pointer reaches the new body, leaves this one, heads away
    /// from the new body or presses off the panel (`shrinkHolds`).
    ///
    /// The open panel changes size under a pointer that has not moved — a dot
    /// to a shorter page above all. On Clipboard the dots sit 306 pt down;
    /// pressing Music's left the pointer below Music's 214 pt body, and the
    /// panel folded `closeDelay` after the press, as if the person had walked
    /// away (owner, 2026-10-18). Folding is for leaving, never for the content
    /// changing size. Held like `landingRect`: only while the panel is open,
    /// and a forced state lets it go.
    ///
    /// `.zero` means nothing is held, and is never a union's starting point:
    /// `CGRect.union` skips only `.null`, so the first hold once reached from
    /// the old body to the screen's origin — on the built-in display, every
    /// point left of and below it (review 5, S1).
    private(set) var shrunkFromRect: CGRect = .zero {
        didSet { updatePressWatch() }
    }

    /// Starts watching presses and scrolls in other apps, returning a token
    /// for `stopWatchingPresses`. Inert here: only the controller's `build`
    /// gives it a real global monitor, so no test process registers one.
    var watchPressesElsewhere: (@escaping @Sendable () -> Void) -> Any? = { _ in nil }
    var stopWatchingPresses: (Any) -> Void = { _ in }
    private var pressWatch: Any?

    /// Starts watching the pointer move over other apps, returning a token
    /// for `stopWatchingMovement`. Inert here, like `watchPressesElsewhere`:
    /// only the controller's `build` gives it a real global monitor.
    var watchMovement: (@escaping @Sendable () -> Void) -> Any? = { _ in nil }
    var stopWatchingMovement: (Any) -> Void = { _ in }
    private var movementWatch: Any?

    /// The monitor stands exactly while a hold does. The sampler alone saw a
    /// press only if a tick caught the button down: resting, it ticks every
    /// 125 ms, and a tap to click is over sooner, so a person clicking in the
    /// browser under where Settings was half the time left Music standing
    /// open over them (re-review 6, F1).
    private func updatePressWatch() {
        if shrunkFromRect.isEmpty {
            guard let pressWatch else { return }
            stopWatchingPresses(pressWatch)
            self.pressWatch = nil
        } else if pressWatch == nil {
            pressWatch = watchPressesElsewhere { [weak self] in
                // AppKit hands a global monitor its events on the main thread
                // in practice, but does not say so; a hop is cheap, and
                // `assumeIsolated` off the main thread is a trap.
                let end: @Sendable () -> Void = {
                    MainActor.assumeIsolated { self?.shrunkFromRect = .zero }
                }
                if Thread.isMainThread { end() } else { DispatchQueue.main.async(execute: end) }
            }
        }
    }

    /// Whether a scroll event is one the person started where it landed — a
    /// mouse wheel, or fingers going down — rather than the momentum of a
    /// page swipe made on the panel, which can still be arriving as the body
    /// shrinks out from under the pointer. Only the first ends a hold.
    nonisolated static func startsAScroll(phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        momentum.isEmpty && (phase.isEmpty || phase.contains(.began))
    }

    /// The nearest the held pointer has come to the new body since the hold
    /// began. Coming no farther than this, give or take `shrinkSlack`, is
    /// standing still or heading for the content; more is going away.
    private var shrinkNearest: CGFloat = 0

    /// What a hand that is resting or reaching still trembles by.
    static let shrinkSlack: CGFloat = 6

    /// A new `closeRect` that no longer holds a pointer the old one held, on
    /// an open panel the pointer is in: the old one keeps holding it. A shrink
    /// on top of a shrink keeps everything still held, measured afresh against
    /// the newest body.
    private func noteShrink(from old: CGRect) {
        guard isInside, isPanelOpen() else { return }
        let point = location()
        if closeRect.contains(point) {
            shrunkFromRect = .zero
        } else if !old.isEmpty, old.contains(point) || shrunkFromRect.contains(point) {
            shrunkFromRect = shrunkFromRect.isEmpty ? old : shrunkFromRect.union(old)
            shrinkNearest = Self.distance(from: point, to: closeRect)
        }
    }

    /// Whether the body the panel shrank from still holds a pointer at
    /// `point`. Not a pointer that has gone anywhere: that area is
    /// click-through now, and an unpinned panel watches no clicks of its own,
    /// so from Settings back to Music a person could work in the browser
    /// under where Settings was while Music stood open over them (review 5,
    /// S3). A pointer heading away from the new body ends it, and so does a
    /// press or a scroll off the panel — in whatever app is under it — which
    /// `watchPressesElsewhere` reports and a held button read here backs up.
    private func shrinkHolds(_ point: CGPoint) -> Bool {
        guard !shrunkFromRect.isEmpty, shrunkFromRect.contains(point) else { return false }
        if buttonsHeld(), !interactiveRect.contains(point), !isDragging() { return false }
        return Self.distance(from: point, to: closeRect) <= shrinkNearest + Self.shrinkSlack
    }

    /// Whether the open panel counts a pointer at `point` as on it beyond its
    /// body: the island it opened from, until the pointer first reaches the
    /// body, and the body it shrank from, while `shrinkHolds`. The controller's
    /// own check asks this rather than keeping a copy of the rule — it had
    /// none of the shrink, and a dot that dropped the keyboard folded the
    /// island 0.6 s later through it (review 5, S2).
    func holdsBeyondBody(at point: CGPoint) -> Bool {
        guard isPanelOpen() else { return false }
        return landingRect.contains(point) || shrinkHolds(point)
    }

    /// How far `point` is from the nearest edge of `rect`, zero inside it.
    nonisolated static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// The closed island as the controller draws it now, in screen
    /// coordinates: every point that takes a click, shoulders and bubble
    /// included. Built from the geometry rather than read from `openRect`,
    /// which stays cut for the open body for a moment after a fold (R-2) and
    /// pads 6 pt where the shoulders reach `closedTopRadius` (R-3).
    var collapsedIsland: (() -> CGRect)?

    /// The closed island a pointer can open the panel from: the controller's
    /// drawing when it has one, else the padded strip and the Shelf's bubble.
    var islandRect: CGRect {
        if let collapsedIsland { return collapsedIsland() }
        return bubbleRect.isEmpty ? openRect : openRect.union(bubbleRect)
    }

    /// Where the pointer is, in screen coordinates. A seam so a test can
    /// place it.
    var location: () -> CGPoint = { NSEvent.mouseLocation }

    /// Exactly the island as it is drawn, with none of `openRect`'s padding.
    ///
    /// The open rect is deliberately 12pt larger so a near miss still opens the
    /// panel — forgiving is right for an action. It is wrong for a *look*: an
    /// appearance driven from it lit up while the pointer was visibly beside
    /// the island. This one is the shape, so what lights is what you are on.
    var hoverRect: CGRect = .zero
    /// Keeps the panel interactive while a drag is being tracked, even if the
    /// pointer wanders outside `interactiveRect` mid-session.
    var isDragging: () -> Bool = { false }
    /// Whether the panel is expanded right now. Read, not assumed: this watcher
    /// tracks where the pointer is, and the panel is opened and closed by other
    /// things too — a drag, the menu bar, a tab that wants the keyboard.
    var isPanelOpen: () -> Bool = { false }
    /// Whether any mouse button is down right now, wherever the press began.
    ///
    /// Asked of an arrival only. A pointer that reaches the notch with a
    /// button held is carrying something — a window by its title bar on its
    /// way to being tiled, a text selection being extended — and unfolding the
    /// panel over it (J-020) answers a hover nobody made. A seam so a test can
    /// hold a button without one being held.
    var buttonsHeld: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// Short enough to feel immediate, long enough that a pointer sweeping
    /// across the top of the screen does not trigger the panel.
    var openDelay = NotchMetrics.openDelay
    var closeDelay = NotchMetrics.closeDelay

    /// Band along the top of the screen that switches sampling to full rate.
    /// The pointer has to cross it to reach the notch, so the fast rate is
    /// always already running by the time hovering matters.
    var warmZone: CGRect = .zero
    /// The same band grown downward by the hysteresis margin. A warm pointer
    /// stays warm while inside this; leaving it cools sampling back down.
    /// Bounded on every side, so warmth cannot survive a move to another
    /// display that merely sits at a similar height.
    var coolZone: CGRect = .zero
    /// How long the pointer may stand still before sampling drops to the idle
    /// rate wherever it stands. Movement re-warms on the next idle tick.
    var restThreshold = NotchMetrics.restThreshold

    private let fastInterval = NotchMetrics.fastPointerInterval
    private let idleInterval = NotchMetrics.idlePointerInterval

    /// The Shelf pane, in screen coordinates; empty whenever the Shelf is not
    /// what the open panel shows. Cutting it empty reports "off the Shelf" at
    /// once, without waiting for a tick: the Delete key that hangs off this
    /// signal must go the moment the Shelf does (`ShelfDeleteKeyHolder`).
    var shelfRect: CGRect = .zero {
        didSet {
            guard shelfRect != oldValue else { return }
            // Re-read with the pointer where it stands, so a rect cut under a
            // pointer already on it counts without a tick's delay.
            sampleShelf(at: shelfRect.isEmpty ? nil : location())
        }
    }
    /// The pointer entered or left `shelfRect`.
    var onShelfChange: ((Bool) -> Void)?
    private var wasOnShelf = false

    /// Reports the Shelf transition for a pointer at `point`; nil is "nowhere",
    /// which is what an empty rect and a stopped sampler both mean. Internal so
    /// a test can drive the transition without a mouse.
    func sampleShelf(at point: CGPoint?) {
        let onShelf = point.map { shelfRect.contains($0) } ?? false
        guard onShelf != wasOnShelf else { return }
        wasOnShelf = onShelf
        onShelfChange?(onShelf)
    }

    var onChange: ((Bool) -> Void)?
    var onInteractiveChange: ((Bool) -> Void)?
    /// The pointer entered or left `hoverRect`.
    var onHoverChange: ((Bool) -> Void)?

    private(set) var isInside = false
    private var timer: Timer?
    private var awaitingSince: Date?
    private var wasInteractive: Bool?
    private var wasHovering: Bool?
    private var isWarm = false
    /// Set by `closedByHand()`: no arrival counts until the pointer has been
    /// sampled outside once.
    private var awaitsDeparture = false
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var lastMovedAt = Date.distantPast

    func start() {
        schedule(warm: false)
        // The timer above does not fire until its first interval has
        // elapsed — up to `idleInterval` (125 ms) away. Left alone, a panel
        // that was just built or rebuilt stays click-through for that whole
        // stretch, since `panel.ignoresMouseEvents` only ever changes from
        // `onInteractiveChange`, which only `tick()` calls. Sample once here,
        // synchronously, so interactivity is correct from the first frame.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        updateMovementWatch()
        awaitingSince = nil
        graceUntil = nil
        // The last sent interactivity dies with the panel it was sent to. The
        // watcher outlives a rebuild, and a fresh panel starts click-through;
        // holding on to the old "already interactive" would swallow the first
        // callback and leave the new panel deaf to clicks until the pointer
        // wandered out and back (#6).
        wasInteractive = nil
        // Nothing is hovered once the sampler stops, and the island must not be
        // left lit for the whole of a lock or a sleep.
        if wasHovering == true { onHoverChange?(false) }
        wasHovering = nil
        // And nothing is on the Shelf once nobody is watching the pointer: the
        // sampler stopping — a lock, a sleep, a rebuild — is a reason to give
        // Delete back.
        sampleShelf(at: nil)
        // The rects are re-cut by whatever starts the watcher again, so a
        // departure owed against the old ones is not owed against the new.
        awaitsDeparture = false
        landingRect = .zero
        shrunkFromRect = .zero
    }

    private func schedule(warm: Bool) {
        timer?.invalidate()
        isWarm = warm
        let interval = warm ? fastInterval : idleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The idle timer may drift by half its beat: nothing it watches for
        // resolves faster than that, and the slack lets the system fold the
        // wake-up into others it was making anyway. The fast timer keeps its
        // precision — it is the one measuring dwell.
        timer.tolerance = warm ? interval / 4 : interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateMovementWatch()
    }

    /// The movement monitor stands exactly while the sampler idles.
    ///
    /// Resting, the sampler ticks every 125 ms and may drift half that again,
    /// and only a tick lets the panel take the mouse (`onInteractiveChange`).
    /// A pointer flicked from rest to the island and clicked inside that
    /// window clicked the menu bar behind it, and the hover lit up to 190 ms
    /// after the pointer arrived — the island read as slow to answer under
    /// exactly the load where the main thread is busiest (review 2026-10-18).
    /// A move into the band now ticks at once, which also warms the sampler;
    /// warm, the 60 Hz timer is quicker than anything a monitor adds, so the
    /// monitor goes and costs nothing while the pointer is near.
    private func updateMovementWatch() {
        if timer == nil || isWarm {
            guard let movementWatch else { return }
            stopWatchingMovement(movementWatch)
            self.movementWatch = nil
        } else if movementWatch == nil {
            movementWatch = watchMovement { [weak self] in
                // Main thread in practice, as with the press monitor; the hop
                // is for the day it is not.
                let moved: @Sendable () -> Void = {
                    MainActor.assumeIsolated { self?.pointerMoved() }
                }
                if Thread.isMainThread { moved() } else { DispatchQueue.main.async(execute: moved) }
            }
        }
    }

    /// One move reported by the monitor while the sampler idles. Only a move
    /// into the band, or one made with the pointer counted inside, is worth a
    /// tick now: anywhere else the idle beat is as good as it ever was, and
    /// the rest of the screen's movement costs one rect test each. Internal
    /// so a test can deliver a move without a mouse.
    func pointerMoved() {
        guard timer != nil, !isWarm else { return }
        guard isInside || warmZone.contains(location()) else { return }
        tick()
    }

    /// Full rate only for a pointer that is actually going somewhere near the
    /// top; eight samples a second otherwise.
    ///
    /// Two conditions, both required. Place: the top band, or anywhere while
    /// the panel is open — with the same hysteresis as ever. Motion: the
    /// pointer must have moved recently, because a parked pointer is not on
    /// its way anywhere, however close to the notch it is parked. The menu
    /// bar, where cursors spend half their lives, lies entirely inside the
    /// band — place alone used to mean full rate for as long as one rested
    /// there. A move into the band is reported at once by the movement
    /// monitor (`updateMovementWatch`); the next idle tick, 125 ms at worst,
    /// is only the fallback for a build without one.
    private func updateRate(for point: CGPoint) {
        if point != lastPoint {
            lastPoint = point
            lastMovedAt = Date()
        }
        let moving = Date().timeIntervalSince(lastMovedAt) < restThreshold
        let near: Bool
        if isInside {
            near = true
        } else if isWarm {
            near = coolZone.contains(point)
        } else {
            near = warmZone.contains(point)
        }
        let warm = near && moving
        guard warm != isWarm else { return }
        schedule(warm: warm)
    }

    /// Force the state, e.g. when the panel is toggled from the menu bar.
    ///
    /// `grace` holds off every automatic close for that long. Something opened
    /// the panel without the pointer — a hotkey, the menu bar, a translation —
    /// and the pointer is wherever it already was, which is usually nowhere
    /// near the notch. Without the grace the very next tick reads "outside",
    /// waits `closeDelay`, and folds the panel roughly a third of a second
    /// after it appeared: the keyboard route to the panel existed but could not
    /// be used.
    func setInside(_ value: Bool, grace: TimeInterval = 0) {
        awaitingSince = nil
        // Asked before the caller opens the panel: the island the open is
        // leaving from. Forced inside on a panel already open — the collapse
        // check's resync, a command — the island it was opened from still
        // stands: that check has just counted the pointer on it (R-4).
        landingRect = value ? (isPanelOpen() ? landingRect : islandRect) : .zero
        shrunkFromRect = value && isPanelOpen() ? shrunkFromRect : .zero
        isInside = value
        graceUntil = grace > 0 ? Date().addingTimeInterval(grace) : nil
        // Whatever forces the state is the newer word on it, so a departure the
        // watcher was still waiting for is no longer owed.
        awaitsDeparture = false
    }

    /// The panel was shut by a deliberate gesture — a second click on the
    /// island, ⌃⌥⌘I again, a click in another app — while the pointer may still
    /// be standing inside the rect the open panel held itself open from.
    ///
    /// `setInside(false)` alone is not enough there, and that is the whole bug
    /// this exists for. `openRect` is still cut for the *open* body while the
    /// panel folds — it only shrinks back to the collapsed strip
    /// `collapseRectShrinkDelay` later, in `NotchController.applyActiveRect` —
    /// so the very next sample reads the pointer that just clicked as an
    /// outside→inside transition, waits `openDelay` (50 ms), and with Open on
    /// Hover switched on reopens the panel it was just told to shut. Click to
    /// close was inoperative in that mode, and the island visibly folded and
    /// unfolded. The pointer has to be seen somewhere else once before an
    /// arrival counts again.
    func closedByHand() {
        setInside(false)
        awaitsDeparture = true
    }

    private var graceUntil: Date?

    /// True while an automatic close is still held off.
    private var withinGrace: Bool {
        guard let graceUntil else { return false }
        guard Date() < graceUntil else {
            self.graceUntil = nil
            return false
        }
        return true
    }

    private func tick() {
        let point = location()
        updateRate(for: point)

        let interactive = isDragging() || interactiveRect.contains(point) || bubbleRect.contains(point)
        if wasInteractive != interactive {
            wasInteractive = interactive
            onInteractiveChange?(interactive)
        }

        // Reported from the sampler rather than from a SwiftUI `.onHover`.
        // The panel ignores mouse events until this same tick decides it is
        // interactive, so a SwiftUI hover never arrives for the frame that
        // matters — and when the pointer is already inside as tracking begins,
        // no entered event is sent at all. The sampler has the pointer either
        // way, and this is the only reading that does not depend on the window
        // already having agreed to listen.
        sampleShelf(at: point)

        let hovering = hoverRect.contains(point)
        if wasHovering != hovering {
            wasHovering = hovering
            onHoverChange?(hovering)
        }

        // Open, the body holds the panel, and so does the island it opened
        // from until the pointer first reaches the body (`landingRect`), and
        // the body it shrank out of until the pointer reaches the new one or
        // leaves the old (`shrunkFromRect`).
        let onBody = closeRect.contains(point)
        if isInside, onBody {
            landingRect = .zero
            shrunkFromRect = .zero
        }
        let onShrunkFrom = isPanelOpen() && shrinkHolds(point)
        if isInside {
            // Once ended, a hold stays ended: a pointer that went away and
            // came back is on the panel by the body or not at all.
            if onShrunkFrom {
                shrinkNearest = min(shrinkNearest, Self.distance(from: point, to: closeRect))
            } else {
                shrunkFromRect = .zero
            }
        }
        let inside = isInside ? onBody || holdsBeyondBody(at: point) : openRect.contains(point)

        // Whether the panel is open and where the pointer is are two separate
        // facts, and only one of them is tracked here. They are supposed to
        // agree, but every path that opens the panel without the pointer —
        // a drop, the menu bar, a tab claiming the keyboard — is a chance for
        // them to come apart, and the shape that costs the user something is
        // always the same: a panel standing open with the mouse nowhere near
        // it, waiting for a hover that already happened. Whatever led there,
        // the pointer is the authority, so say so again.
        // A drag is the one time the panel is meant to stand open with the
        // pointer off it: it was opened to be dropped onto.
        // The pointer arriving is the real signal; once it is on the panel the
        // grace has done its job and normal hover rules resume.
        if inside { graceUntil = nil }

        // A deliberate close is not undone by the pointer that performed it.
        // Until that pointer has been seen off the panel once, an "arrival" is
        // only the click that shut it, read back — see `closedByHand()`.
        if awaitsDeparture {
            guard !inside else {
                awaitingSince = nil
                return
            }
            awaitsDeparture = false
        }

        if !inside, !isInside, !isDragging(), isPanelOpen() {
            guard !withinGrace else { return }
            guard let start = awaitingSince else {
                awaitingSince = Date()
                return
            }
            guard Date().timeIntervalSince(start) >= closeDelay else { return }
            awaitingSince = nil
            onChange?(false)
            return
        }

        guard inside != isInside else {
            awaitingSince = nil
            return
        }
        // A button held through the arrival means the pointer is dragging
        // something of another app's through the notch, not standing on the
        // island; the arrival has not happened yet. Once the button comes up
        // with the pointer still there, the dwell starts from scratch and it
        // counts like any other hover. Two kinds of held press are not this:
        // a file drag, which arrives through `onDragEntered` and is in
        // `isDragging`, and a press that began on the panel itself, which
        // `isDragging` also carries.
        if inside, buttonsHeld(), !isDragging() {
            awaitingSince = nil
            return
        }
        // A drag in flight is the one time the panel is meant to stand open with
        // the pointer off it: it was opened to be dropped onto, or a card is
        // being dragged out of it. The already-outside branch above has asked
        // this all along and this one — the departure itself — did not, which is
        // the shape a drag actually takes: click the island open, go to the
        // Shelf, drag a card to the Desktop, and 0.32 s after the pointer left
        // `closeRect` the panel folded and tore down the very view the drag
        // session was still running from. It was unreachable only because every
        // click used to pin, and `holdsOpen` refused the close on the way out.
        //
        // `isInside` is deliberately left standing rather than flipped: when the
        // drag ends with the pointer still away, the departure is read again from
        // scratch and the panel folds then, which is what it owed all along.
        if !inside, isDragging() {
            awaitingSince = nil
            return
        }
        // Same hold-off for the ordinary inside→outside transition: a
        // programmatic open sets `isInside` true with the pointer elsewhere,
        // and that disagreement resolves here one tick later.
        if !inside, withinGrace { return }
        guard let start = awaitingSince else {
            awaitingSince = Date()
            return
        }
        guard Date().timeIntervalSince(start) >= (inside ? openDelay : closeDelay) else { return }
        awaitingSince = nil
        // An arrival at the closed island carries that island into the open
        // panel's close rule; a departure ends it.
        landingRect = inside && !isPanelOpen() ? islandRect : .zero
        shrunkFromRect = .zero
        isInside = inside
        onChange?(inside)
    }
}

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
    var closeRect: CGRect = .zero
    /// Where the panel takes clicks. Everywhere else the window must let them
    /// through, so this doubles as the `ignoresMouseEvents` trigger.
    var interactiveRect: CGRect = .zero

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
    /// there. Movement is noticed on the next idle tick, 125 ms at worst,
    /// which is less than the dwell a hover has to survive anyway — so
    /// warming up is never the thing anybody is waiting on.
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
        isInside = value
        graceUntil = grace > 0 ? Date().addingTimeInterval(grace) : nil
    }

    /// Ends the grace early — the pointer arriving on the panel is a better
    /// signal than any timer, and a deliberate close must not have to wait.
    func endGrace() {
        graceUntil = nil
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
        let point = NSEvent.mouseLocation
        updateRate(for: point)

        let interactive = isDragging() || interactiveRect.contains(point)
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
        let hovering = hoverRect.contains(point)
        if wasHovering != hovering {
            wasHovering = hovering
            onHoverChange?(hovering)
        }

        let inside = (isInside ? closeRect : openRect).contains(point)

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
        isInside = inside
        onChange?(inside)
    }
}

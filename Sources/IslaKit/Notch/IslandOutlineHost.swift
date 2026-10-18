import AppKit
import QuartzCore

/// A layer-backed view that draws what its layers draw and takes no events:
/// the island's outline is under and over the SwiftUI content, never in the
/// way of it.
final class OutlineSurfaceView: NSView {
    var onResize: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        // Nothing here is for VoiceOver: the island's one element is the
        // Isla button SwiftUI draws (`islandAccessibility`).
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }

    /// Never the target of a click, a drag or a tracking area: the panel's
    /// hit region is cut by `NotchRootView.activeRect` and answered by the
    /// SwiftUI views, and a full-window layer in front of them would take it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
}

/// The island's outline, drawn by Core Animation instead of by SwiftUI
/// (redesign spec §19.12, "the island lags while I work").
///
/// It used to be three SwiftUI shapes — the black fill with its shadow, the
/// mask the content is cut by, the 2 pt line — each re-evaluated, re-pathed and
/// re-rasterised on the main thread on every frame of every spring, beside the
/// layout of everything inside the island. A Mac with its cores taken by
/// builds drops frames in exactly that thread. The outline is now three
/// `CAShapeLayer`s whose paths, colours and shadow move on animations the
/// render server runs: once a change has begun, the main thread can stall for
/// as long as it likes and the outline arrives on time.
///
/// - `backdrop`, under the SwiftUI content: the fill and, with an explicit
///   `shadowPath`, the shadow (no offscreen pass to find the silhouette).
/// - The content view's layer is masked by the same outline, so nothing inside
///   the island draws outside it on any frame — the R8c hard rule — whatever
///   state SwiftUI's own layout is in when the outline reaches the frame.
/// - `overlay`, over the content: the line, so a pane's edge can never lie
///   over the border.
///
/// What the outline is comes from the SwiftUI shell, which decides it from the
/// same properties it always drew it from (`NotchContentView.outlineState`);
/// how it moves comes from the transaction that change carried
/// (`OutlineCurve.of`), so the curve SwiftUI would have used is the curve the
/// layers use, and Reduce Motion, the pop-up's own spring and `Theme.close`'s
/// delay are honoured without being named here.
///
/// A change is kept in flight per part, as SwiftUI keeps one per value: the
/// pointer arriving while the island opens changes the fill on a short ease,
/// and must leave the open's spring on the shape alone.
@MainActor
final class IslandOutlineHost {
    let backdrop: OutlineSurfaceView
    let overlay: OutlineSurfaceView
    private(set) var windowSize: CGSize

    /// Progress per second past which an outline counts as moving: a tenth of
    /// the island's peak speed (about four a second), so one that has all but
    /// arrived is not turned round as if it were flying.
    private static let movingFast = 0.4

    let fillLayer = CAShapeLayer()
    let strokeLayer = CAShapeLayer()
    let maskLayer = CAShapeLayer()
    /// The bubble's mask: everything but the island (even-odd).
    let bubbleMaskLayer = CAShapeLayer()

    private weak var content: NSView?
    private var contentFlipped = true
    private weak var bubble: NSView?
    private var bubbleFlipped = true

    /// The view that owns the host's showing: the bridge that last asked for
    /// anything. A bridge going away hides the outline only if it is that one,
    /// so a shell rebuilt before the old one is torn down keeps its outline.
    weak var owner: AnyObject?

    /// The state last asked for, or nil while the host is hidden.
    private(set) var target: OutlineState?

    private var shapeFlight: Flight<OutlineShape>?
    private var fillFlight: Flight<OutlineColor>?
    private var strokeFlight: Flight<OutlineColor>?
    private var shadowFlight: Flight<OutlineOpacity>?

    /// Seen by the tests: every state the shell asked for and on what curve.
    var onApply: ((OutlineState, OutlineCurve) -> Void)?

    /// One part's change in flight: where it began, where it is going, on what
    /// curve, carrying how much momentum, and for how long.
    private struct Flight<Value: OutlineMixable> {
        var from: Value
        var to: Value
        var curve: OutlineCurve
        var velocity: Double
        var start: CFTimeInterval
        var duration: Double

        func isActive(at now: CFTimeInterval) -> Bool { now - start < duration }

        func value(at now: CFTimeInterval) -> Value {
            guard isActive(at: now) else { return to }
            return from.mixed(to: to, curve.progress(at: now - start, initialVelocity: velocity))
        }

        /// Progress per second.
        func rate(at now: CFTimeInterval) -> Double {
            guard isActive(at: now) else { return 0 }
            return curve.velocity(at: now - start, initialVelocity: velocity)
        }
    }

    init(windowSize: CGSize) {
        self.windowSize = windowSize
        let frame = CGRect(origin: .zero, size: windowSize)
        backdrop = OutlineSurfaceView(frame: frame)
        overlay = OutlineSurfaceView(frame: frame)
        for view in [backdrop, overlay] {
            view.autoresizingMask = [.width, .height]
            view.isHidden = true
        }

        fillLayer.fillColor = OutlineColor.black.cgColor
        fillLayer.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        fillLayer.shadowOffset = .zero
        fillLayer.shadowRadius = Theme.islandShadowRadius
        fillLayer.shadowOpacity = 0

        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .butt
        strokeLayer.lineJoin = .miter

        maskLayer.fillColor = OutlineColor.black.cgColor
        bubbleMaskLayer.fillColor = OutlineColor.black.cgColor
        bubbleMaskLayer.fillRule = .evenOdd

        backdrop.layer?.addSublayer(fillLayer)
        overlay.layer?.addSublayer(strokeLayer)
        fillLayer.frame = frame
        strokeLayer.frame = frame

        backdrop.onResize = { [weak self] size in self?.resize(to: size) }
    }

    /// The view the outline cuts. Its layer is masked while the host shows.
    func attach(content view: NSView) {
        view.wantsLayer = true
        content = view
        contentFlipped = view.isFlipped
    }

    /// The view that draws what lies beside the island. Its layer is masked to
    /// the area outside the outline, so a bubble the main thread has not yet
    /// taken away cannot lie over the island while the outline grows.
    func attach(bubble view: NSView) {
        view.wantsLayer = true
        bubble = view
        bubbleFlipped = view.isFlipped
    }

    var isShowing: Bool { target != nil }

    // MARK: Showing

    /// Draws the outline at `new`, getting there on `curve`, from wherever it
    /// is drawn now — which, if an earlier change is still moving, is partway
    /// along it, carrying its momentum into a spring. A part of the outline
    /// that `new` does not change keeps the motion it is in.
    func apply(_ new: OutlineState, curve: OutlineCurve, now: CFTimeInterval = CACurrentMediaTime()) {
        onApply?(new, curve)
        guard windowSize.width > 0, windowSize.height > 0 else { return }
        // The same ask again, as SwiftUI makes whenever the shell re-renders
        // for another reason: nothing to do, and certainly not to restart.
        if let target, target == new { return }

        let before = drawn(at: now)
        let previous = target
        target = new

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        backdrop.isHidden = false
        overlay.isHidden = false
        showMask()
        strokeLayer.lineWidth = CGFloat(new.strokeWidth)

        if before == nil || previous?.shape != new.shape {
            // A shadow that is nothing before and after has no silhouette to
            // follow, and the compact activities that cost the most frames
            // (the pill, the peek, the charger) cast none.
            let casts = (before?.shadowOpacity ?? 0) > 0 || new.shadowOpacity > 0
            moveShape(from: before?.shape, to: new.shape, curve: curve, now: now, followsShadow: casts)
        }
        if before == nil || previous?.fill != new.fill {
            fillFlight = recolour(
                fillLayer, "fillColor", from: before?.fill, to: new.fill, curve: curve, now: now,
                model: { self.fillLayer.fillColor = $0 }
            )
        }
        if before == nil || previous?.stroke != new.stroke {
            strokeFlight = recolour(
                strokeLayer, "strokeColor", from: before?.stroke, to: new.stroke, curve: curve, now: now,
                model: { self.strokeLayer.strokeColor = $0 }
            )
        }
        if before == nil || previous?.shadow != new.shadow {
            moveShadow(from: before?.shadow, to: new.shadow, curve: curve, now: now)
        }
    }

    /// Takes the outline away without a motion: the lock screen draws its own
    /// pill, and the island's SwiftUI shell, which this follows, is not on
    /// screen to ask for anything.
    func hide() {
        target = nil
        shapeFlight = nil
        fillFlight = nil
        strokeFlight = nil
        shadowFlight = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fillLayer, strokeLayer, maskLayer, bubbleMaskLayer] { layer.removeAllAnimations() }
        backdrop.isHidden = true
        overlay.isHidden = true
        if content?.layer?.mask === maskLayer { content?.layer?.mask = nil }
        if bubble?.layer?.mask === bubbleMaskLayer { bubble?.layer?.mask = nil }
        CATransaction.commit()
    }

    /// Where the outline is drawn at `now`: its target, or partway to it.
    func drawn(at now: CFTimeInterval = CACurrentMediaTime()) -> OutlineState? {
        guard var state = target else { return nil }
        if let flight = shapeFlight { state.shape = flight.value(at: now) }
        if let flight = fillFlight { state.fill = flight.value(at: now) }
        if let flight = strokeFlight { state.stroke = flight.value(at: now) }
        if let flight = shadowFlight { state.shadow = flight.value(at: now) }
        return state
    }

    // MARK: The shape

    private func moveShape(
        from: OutlineShape?, to: OutlineShape, curve: OutlineCurve, now: CFTimeInterval, followsShadow: Bool
    ) {
        var velocity = 0.0
        var curve = curve
        if let flight = shapeFlight, let from, case .spring = curve {
            velocity = carriedVelocity(of: flight, to: to, from: from, at: now)
            // Turning a moving outline round is not the moment for
            // `Theme.close`'s 30 ms head start (the body leaves before the
            // shape comes for it): the outline would stand still for it and
            // go on at its old speed. It turns now, with the speed it had.
            if abs(velocity) > Self.movingFast { curve = curve.withoutDelay }
        }
        shapeFlight = nil
        for key in ["outline.path", "outline.shadowPath"] { fillLayer.removeAnimation(forKey: key) }
        strokeLayer.removeAnimation(forKey: "outline.path")
        maskLayer.removeAnimation(forKey: "outline.path")
        bubbleMaskLayer.removeAnimation(forKey: "outline.path")

        let fill = OutlinePaths.fill(to, in: windowSize, flipped: false)
        fillLayer.path = fill
        fillLayer.shadowPath = fill
        strokeLayer.path = OutlinePaths.stroke(to, in: windowSize, flipped: false)
        maskLayer.path = OutlinePaths.fill(to, in: windowSize, flipped: contentFlipped)
        bubbleMaskLayer.path = OutlinePaths.outside(to, in: windowSize, flipped: bubbleFlipped)

        guard let from, let run = sample(from: from, to: to, curve: curve, velocity: velocity, now: now) else { return }
        shapeFlight = run.flight
        let fills = run.values.map { OutlinePaths.fill($0, in: windowSize, flipped: false) }
        add(fillLayer, "path", fills, run.flight.duration, begin: now)
        // The shadow's silhouette is the shape's own: the same keyframes, so
        // it never lags the fill by a frame.
        if followsShadow { add(fillLayer, "shadowPath", fills, run.flight.duration, begin: now) }
        add(strokeLayer, "path", run.values.map { OutlinePaths.stroke($0, in: windowSize, flipped: false) }, run.flight.duration, begin: now)
        let cuts = contentFlipped ? run.values.map { OutlinePaths.fill($0, in: windowSize, flipped: true) } : fills
        add(maskLayer, "path", cuts, run.flight.duration, begin: now)
        add(bubbleMaskLayer, "path", run.values.map { OutlinePaths.outside($0, in: windowSize, flipped: bubbleFlipped) },
            run.flight.duration, begin: now)
    }

    private func moveShadow(from: OutlineOpacity?, to: OutlineOpacity, curve: OutlineCurve, now: CFTimeInterval) {
        shadowFlight = nil
        fillLayer.removeAnimation(forKey: "outline.shadowOpacity")
        fillLayer.shadowOpacity = Float(to.value)
        guard let from, let run = sample(from: from, to: to, curve: curve, velocity: 0, now: now) else { return }
        shadowFlight = run.flight
        add(fillLayer, "shadowOpacity", run.values.map { Float($0.value) }, run.flight.duration, begin: now)
    }

    private func recolour(
        _ layer: CAShapeLayer, _ key: String, from: OutlineColor?, to: OutlineColor,
        curve: OutlineCurve, now: CFTimeInterval, model: (CGColor) -> Void
    ) -> Flight<OutlineColor>? {
        layer.removeAnimation(forKey: "outline.\(key)")
        model(to.cgColor)
        guard let from, let run = sample(from: from, to: to, curve: curve, velocity: 0, now: now) else { return nil }
        add(layer, key, run.values.map(\.cgColor), run.flight.duration, begin: now)
        return run.flight
    }

    /// The change as a flight and the part sampled along it, or nothing if
    /// there is no motion to make: no curve, nothing to travel, or no way of
    /// telling where it began.
    private func sample<V: OutlineMixable>(
        from: V, to: V, curve: OutlineCurve, velocity: Double, now: CFTimeInterval
    ) -> (flight: Flight<V>, values: [V])? {
        guard curve != .instant, from != to else { return nil }
        let (duration, progress) = curve.keyframes(initialVelocity: velocity)
        guard progress.count > 1, duration > 0 else { return nil }
        let flight = Flight(from: from, to: to, curve: curve, velocity: velocity, start: now, duration: duration)
        return (flight, progress.map { from.mixed(to: to, $0) })
    }

    // MARK: Layers

    /// `begin` is the moment the change was asked for, not the next commit:
    /// the flight kept here, which an interruption starts from, counts from
    /// the same moment, so the layer and the model cannot disagree by the
    /// frame the commit waits for.
    private func add(_ layer: CALayer, _ keyPath: String, _ values: [Any], _ duration: CFTimeInterval, begin: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = layer.convertTime(begin, from: nil)
        layer.add(animation, forKey: "outline.\(keyPath)")
    }

    /// Both masks are as big as the window and start at its corner: the views
    /// they cut are window-sized, and the frame is the window's, not whatever
    /// the view's layer reports at the moment (a resized hosting view's layer
    /// can lag the host's own idea of the window).
    private func showMask() {
        let frame = CGRect(origin: .zero, size: windowSize)
        if let layer = content?.layer {
            if maskLayer.frame != frame { maskLayer.frame = frame }
            if layer.mask !== maskLayer { layer.mask = maskLayer }
        }
        if let layer = bubble?.layer {
            if bubbleMaskLayer.frame != frame { bubbleMaskLayer.frame = frame }
            if layer.mask !== bubbleMaskLayer { layer.mask = bubbleMaskLayer }
        }
    }

    private func resize(to size: CGSize) {
        guard size != windowSize, size.width > 0, size.height > 0 else { return }
        windowSize = size
        let frame = CGRect(origin: .zero, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = frame
        strokeLayer.frame = frame
        maskLayer.frame = frame
        bubbleMaskLayer.frame = frame
        CATransaction.commit()
        // The window was cut again (a display change rebuilds the panel, but
        // a root view can be resized under a live host): the paths are the old
        // window's, so draw the outline again where it was going, without a
        // motion.
        if let target {
            self.target = nil
            shapeFlight = nil
            apply(target, curve: .instant)
        }
    }

    /// How much of the next change's way an interrupted spring is already
    /// covering each second: the shape's velocity, projected on the way it now
    /// has to go. Reversing a spring that is opening starts the close at the
    /// speed the open had, not from rest — as SwiftUI's own springs do.
    private func carriedVelocity(of flight: Flight<OutlineShape>, to new: OutlineShape, from: OutlineShape, at now: CFTimeInterval) -> Double {
        let rate = flight.rate(at: now)
        let moving = zip(flight.from.numbers, flight.to.numbers).map { ($1 - $0) * rate }
        let way = zip(new.numbers, from.numbers).map { $0 - $1 }
        let distance = way.reduce(0) { $0 + $1 * $1 }
        guard distance > 1e-6 else { return 0 }
        return zip(moving, way).reduce(0) { $0 + $1.0 * $1.1 } / distance
    }
}

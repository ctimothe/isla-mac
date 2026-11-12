import QuartzCore
import SwiftUI

/// The lock card banner's ring, moved by Core Animation along the song's clock
/// (Batch 22, 2026-11-05).
///
/// The ring was a SwiftUI circle trimmed to the position, so every 0.1 s tick
/// re-ran the whole card to turn it a fraction of a degree, and a pass of the
/// card's graph, layout and render came with each one: the cost the player's
/// bar paid until Batch 20 (`PlaybackFill`), on a banner that had nothing else
/// on the clock. The arc is now one shape layer whose stroke end is a single
/// animation from where the song is to where it stops, the bar's own plan in
/// shares of the song rather than in points, laid again only when the clock
/// changes course: a seek, a pause, a new rate, a correction.
struct PlaybackRing: NSViewRepresentable {
    struct Input: Equatable {
        var motion: PlaybackClock.Motion
        var duration: TimeInterval
        /// The frame's side; the ring is drawn square in it.
        var side: CGFloat
        /// How far inside the frame the circle runs: `Circle().inset(by:)`'s.
        var inset: CGFloat
        var lineWidth: CGFloat
    }

    let input: Input
    let color: Color

    func makeNSView(context: Context) -> PlaybackRingView { PlaybackRingView() }

    func updateNSView(_ view: PlaybackRingView, context: Context) {
        view.update(input, color: color.resolve(in: context.environment).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlaybackRingView, context: Context) -> CGSize? {
        CGSize(width: input.side, height: input.side)
    }

    static func dismantleNSView(_ view: PlaybackRingView, coordinator: ()) {
        view.stop()
    }

    /// The arc's share of the circle over time: the bar's plan, one point
    /// wide, so its widths are the share of the song played. Pure, so the
    /// keys are tested without a layer.
    static func plan(_ input: Input, monoNow: TimeInterval) -> (run: KaraokePlan.Run, visible: Bool) {
        PlaybackFill.plan(
            .init(motion: input.motion, duration: input.duration, width: 1, height: 1, radius: 0),
            monoNow: monoNow
        )
    }

    /// The circle the arc is stroked along: from 12 o'clock, clockwise as it
    /// is seen, which is where the trimmed SwiftUI circle turned from. Built
    /// for a layer whose content is drawn `flipped` (y down on screen) or not,
    /// because which one a layer is depends on the views above it, and an arc
    /// drawn for the wrong one starts at 6 o'clock and runs backwards.
    static func path(side: CGFloat, inset: CGFloat, flipped: Bool) -> CGPath {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let radius = max(0, side / 2 - inset)
        let path = CGMutablePath()
        // Seen with y up, the top is +π/2 and clockwise runs to lower angles;
        // with y down, the top is −π/2 and clockwise runs to higher ones.
        if flipped {
            path.addArc(center: centre, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        } else {
            path.addArc(center: centre, radius: radius, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true)
        }
        return path
    }
}

/// One layer-backed view holding the ring's arc, whose stroke end is the
/// plan's animation, so the render server turns the ring and the card's main
/// thread is not woken between the clock's changes of course.
final class PlaybackRingView: NSView {
    static let ringKey = "playback.ring"

    private let arc = CAShapeLayer()
    private var animated = false
    /// How many times the arc was laid, for the tests.
    private(set) var installs = 0
    /// The input the arc was last laid for. Kept, not replaced by a reading
    /// that agrees with it, so small corrections cannot add up unseen.
    private(set) var input: PlaybackRing.Input?
    /// Which way the arc's path was built, so a layer moved under a view
    /// drawn the other way round is built again.
    private var builtFlipped: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.anchorPoint = .zero
        layer?.addSublayer(arc)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The ring is the play button's face: the press belongs to the button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The button around it is what VoiceOver finds.
    override func isAccessibilityElement() -> Bool { false }

    /// Whether `next` is the ring already drawn: the same circle, and either
    /// the same still position or the same clock read again.
    static func same(_ drawn: PlaybackRing.Input, _ next: PlaybackRing.Input) -> Bool {
        guard drawn.duration == next.duration, drawn.side == next.side, drawn.inset == next.inset,
              drawn.lineWidth == next.lineWidth else { return false }
        switch (drawn.motion, next.motion) {
        case let (.still(a), .still(b)): return a == b
        case let (.moving(a), .moving(b)): return a.agrees(with: b)
        default: return false
        }
    }

    /// The arc still on the layer, its animation still on it, and its path
    /// built for the way the layer is drawn now. See `PlaybackFillView.isLive`
    /// for why AppKit can take any of those away.
    private var isLive: Bool {
        arc.superlayer === layer
            && (!animated || arc.animation(forKey: Self.ringKey) != nil)
            && builtFlipped == arc.contentsAreFlipped()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        repair()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        repair()
    }

    private func repair() {
        guard window != nil, input != nil, !isLive else { return }
        install()
    }

    func update(_ next: PlaybackRing.Input, color: CGColor) {
        if arc.strokeColor != color {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.strokeColor = color
            CATransaction.commit()
        }
        if let input, PlaybackRingView.same(input, next), isLive { return }
        input = next
        install()
    }

    func stop() {
        arc.removeAnimation(forKey: Self.ringKey)
        input = nil
    }

    private func install() {
        guard let input else { return }
        if arc.superlayer !== layer { layer?.addSublayer(arc) }
        let plan = PlaybackRing.plan(input, monoNow: SongClock.hostNow())
        let flipped = arc.contentsAreFlipped()
        installs += 1
        CATransaction.begin()
        // A seek lands at once: the ring is never eased there, only carried
        // on from there by the clock.
        CATransaction.setDisableActions(true)
        arc.removeAnimation(forKey: Self.ringKey)
        arc.frame = CGRect(x: 0, y: 0, width: input.side, height: input.side)
        arc.path = PlaybackRing.path(side: input.side, inset: input.inset, flipped: flipped)
        builtFlipped = flipped
        arc.lineWidth = input.lineWidth
        arc.strokeEnd = plan.run.start
        // A round cap draws a dot at a zero-length arc, which the trimmed
        // circle never did: nothing is shown until something is played.
        arc.opacity = plan.visible ? 1 : 0
        let begin = plan.run.keys.first.map { layer?.convertTime($0.mono, from: nil) ?? $0.mono }
        let animation = begin.flatMap { plan.run.animation(beginTime: $0, keyPath: "strokeEnd") }
        if let animation { arc.add(animation, forKey: Self.ringKey) }
        animated = animation != nil
        CATransaction.commit()
    }

    // For the tests.
    var strokeEnd: CGFloat { arc.strokeEnd }
    var arcOpacity: Float { arc.opacity }
    var arcPath: CGPath? { arc.path }
    var arcIsFlipped: Bool { arc.contentsAreFlipped() }
    var runningAnimation: CAAnimation? { arc.animation(forKey: Self.ringKey) }
    func dropAnimationForTests() { arc.removeAnimation(forKey: Self.ringKey) }
}

import QuartzCore
import SwiftUI

/// The playback bar's fill, moved by Core Animation along the song's clock
/// (Batch 20, 2026-10-30).
///
/// The fill was a SwiftUI shape whose width was the position, so every 0.1 s
/// tick re-ran the scrubber to move it, and a pass of the panel's graph,
/// layout and render came with each one: open on the player with no lyrics,
/// the bar and the times were the whole of what the idle-cost lab measured,
/// 0.7 % of a core. A three-minute song moves a 310 pt bar 0.13 pt a tick,
/// under a pixel. The fill is now one layer whose width is a single animation
/// from where the song is to where it ends, worked out from the clock as the
/// word sweep's edge is (`KaraokeTrack`), and laid again only when the clock
/// changes course: a seek, a pause, a new rate, a correction.
struct PlaybackFill: NSViewRepresentable {
    struct Input: Equatable {
        var motion: PlaybackClock.Motion
        var duration: TimeInterval
        var width: CGFloat
        var height: CGFloat
        var radius: CGFloat
        /// The narrowest the fill is drawn once anything is lit: the
        /// player's bar is never a sliver thinner than it is tall.
        var floor: CGFloat = 0
    }

    let input: Input
    let color: Color

    func makeNSView(context: Context) -> PlaybackFillView { PlaybackFillView() }

    func updateNSView(_ view: PlaybackFillView, context: Context) {
        view.update(input, color: color.resolve(in: context.environment).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlaybackFillView, context: Context) -> CGSize? {
        CGSize(width: input.width, height: input.height)
    }

    static func dismantleNSView(_ view: PlaybackFillView, coordinator: ()) {
        view.stop()
    }

    /// The fill's width over time as one bar's run (`KaraokePlan.Run`, the
    /// word sweep's own): its width now, and keys from now to where the song
    /// stops. Pure, so the keys are tested without a layer.
    static func plan(_ input: Input, monoNow: TimeInterval) -> (run: KaraokePlan.Run, visible: Bool) {
        func lit(_ position: TimeInterval) -> CGFloat {
            guard input.duration > 0, position.isFinite else { return 0 }
            return input.width * CGFloat(min(max(position / input.duration, 0), 1))
        }
        func drawn(_ lit: CGFloat) -> CGFloat { max(lit, input.floor) }
        let rect = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        switch input.motion {
        case .still(let position):
            let now = lit(position)
            return (.init(rect: rect, start: drawn(now), keys: []), now > 0)
        case .moving(let clock):
            let now = clock.position(at: monoNow)
            let start = drawn(lit(now))
            // Where the song stops: its end, or the clock's cap when that
            // comes first (a held song's length can differ from the clock's).
            let stop = min(input.duration, clock.cap ?? input.duration)
            guard clock.rate > 0, now < stop, let end = clock.mono(atSong: stop) else {
                return (.init(rect: rect, start: start, keys: []), lit(now) > 0)
            }
            var keys = [KaraokePlan.Run.Key(mono: monoNow, width: start)]
            // Held at the floor until the lit width passes it.
            if lit(now) < input.floor, input.width > 0 {
                let song = TimeInterval(input.floor / input.width) * input.duration
                if song < stop, let reached = clock.mono(atSong: song), reached > monoNow {
                    keys.append(.init(mono: reached, width: input.floor))
                }
            }
            keys.append(.init(mono: end, width: drawn(lit(stop))))
            return (.init(rect: rect, start: start, keys: keys), true)
        }
    }
}

/// One layer-backed view holding the fill's bar, whose width is the plan's
/// animation, so the render server moves the bar and the app's main thread is
/// not woken between the clock's changes of course.
final class PlaybackFillView: NSView {
    static let fillKey = "playback.fill"

    private let bar = CALayer()
    private var animated = false
    /// How many times the bar was laid, for the tests.
    private(set) var installs = 0
    /// The input the bar was last laid for. Kept, not replaced by a reading
    /// that agrees with it, so small corrections cannot add up unseen.
    private(set) var input: PlaybackFill.Input?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bar.anchorPoint = .zero
        bar.cornerCurve = .continuous
        layer?.addSublayer(bar)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The drag and the hover belong to the scrubber around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The scrubber is one slider to VoiceOver (`playbackPositionAccessibility`).
    override func isAccessibilityElement() -> Bool { false }

    /// Whether `next` is the fill already drawn: the same bar, and either the
    /// same still position or the same clock read again.
    static func same(_ drawn: PlaybackFill.Input, _ next: PlaybackFill.Input) -> Bool {
        guard drawn.duration == next.duration, drawn.width == next.width, drawn.height == next.height,
              drawn.radius == next.radius, drawn.floor == next.floor else { return false }
        switch (drawn.motion, next.motion) {
        case let (.still(a), .still(b)): return a == b
        case let (.moving(a), .moving(b)): return a.agrees(with: b)
        default: return false
        }
    }

    /// The bar still on the layer and its animation still on it. AppKit can
    /// give a view a new layer, and a layer moved between trees can lose its
    /// animations. The word sweep's copy of this was repaired by the next
    /// tick; the fill hears from SwiftUI at most twice a second while playing
    /// and never while paused, so it also repairs itself when it changes
    /// window or screen, which is when AppKit does either.
    private var isLive: Bool {
        bar.superlayer === layer && (!animated || bar.animation(forKey: Self.fillKey) != nil)
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

    func update(_ next: PlaybackFill.Input, color: CGColor) {
        if bar.backgroundColor != color {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.backgroundColor = color
            CATransaction.commit()
        }
        if let input, Self.same(input, next), isLive { return }
        input = next
        install()
    }

    func stop() {
        bar.removeAnimation(forKey: Self.fillKey)
        input = nil
    }

    private func install() {
        guard let input else { return }
        if bar.superlayer !== layer { layer?.addSublayer(bar) }
        let plan = PlaybackFill.plan(input, monoNow: SongClock.hostNow())
        installs += 1
        CATransaction.begin()
        // A seek lands under the pointer at once: the bar is never eased
        // there, only carried on from there by the clock.
        CATransaction.setDisableActions(true)
        bar.removeAnimation(forKey: Self.fillKey)
        bar.position = .zero
        bar.bounds = CGRect(x: 0, y: 0, width: plan.run.start, height: input.height)
        bar.cornerRadius = min(input.radius, input.height / 2)
        bar.opacity = plan.visible ? 1 : 0
        // Keys are moments on the media clock, which is Core Animation's own
        // (`KaraokeTrackTests`).
        let begin = plan.run.keys.first.map { layer?.convertTime($0.mono, from: nil) ?? $0.mono }
        let animation = begin.flatMap { plan.run.animation(beginTime: $0) }
        if let animation { bar.add(animation, forKey: Self.fillKey) }
        animated = animation != nil
        CATransaction.commit()
    }

    // For the tests.
    var barWidth: CGFloat { bar.bounds.width }
    var barOpacity: Float { bar.opacity }
    var runningAnimation: CAAnimation? { bar.animation(forKey: Self.fillKey) }
    func dropAnimationForTests() { bar.removeAnimation(forKey: Self.fillKey) }
}

import AppKit
import QuartzCore
import SwiftUI

/// Where the word sweep's edge stands, run by run, from now to the end of the
/// line: keyframes for Core Animation (Batch 19, 2026-10-30).
///
/// The sweep was a `TimelineView` that read the clock on every display frame,
/// so the edge was never older than a frame (F-011). The price was the whole
/// panel laid out and rendered again on each of those frames — 6.2 % of a core
/// on the running Isla open on the player with a word-timed song (B18-H1), and
/// 7.14 % in the idle-cost lab's `open-player-words`. Nothing about the edge
/// needs a frame to be known: between two word stamps it moves at one speed
/// or stands still (`LiveSweep.knots`), and the song's clock is a straight
/// line (`SongClock`). So the plan is the edge's whole path, worked out once,
/// and the render server draws it. Each run is a row of the laid-out line in
/// reading order, filled before the next is touched, exactly as
/// `KaraokeRenderer` fills them; `KaraokeTrackTests` holds every 2 ms of a
/// line against the renderer's own arithmetic.
@MainActor enum KaraokePlan {
    struct Run: Equatable {
        /// The run's box in the line, top-left origin.
        var rect: CGRect
        /// The lit width at the moment the plan was made.
        var start: CGFloat
        /// The lit width from that moment on, straight between keys; empty
        /// when nothing moves. Two keys at one moment are a cut.
        var keys: [Key]

        struct Key: Equatable {
            var mono: TimeInterval
            var width: CGFloat
        }

        /// What Core Animation draws at monotonic time `mono`: the same
        /// linear interpolation between keyframes, and the last one held.
        func width(atMono mono: TimeInterval) -> CGFloat {
            guard let first = keys.first, mono >= first.mono else { return start }
            let index = keys.lastIndex { $0.mono <= mono } ?? 0
            guard index + 1 < keys.count else { return keys[index].width }
            let from = keys[index], to = keys[index + 1]
            let span = to.mono - from.mono
            guard span > 0 else { return to.width }
            return from.width + (to.width - from.width) * CGFloat((mono - from.mono) / span)
        }

        /// The run's keyframes as one animation of its bar's width, beginning
        /// at `beginTime` in the layer's time, which is the plan's moment.
        func animation(beginTime: CFTimeInterval) -> CAKeyframeAnimation? {
            guard let first = keys.first, let last = keys.last, last.mono > first.mono else { return nil }
            let duration = last.mono - first.mono
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.width")
            animation.values = keys.map(\.width)
            animation.keyTimes = keys.map { NSNumber(value: ($0.mono - first.mono) / duration) }
            animation.calculationMode = .linear
            animation.duration = duration
            animation.beginTime = beginTime
            // Held at the end of the line, which is where the edge stays.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            return animation
        }
    }

    /// The plan for a line laid out as `runs`, `full` wide on one unbroken row
    /// when it was cut short, made at monotonic time `monoNow`. With no clock
    /// the edge stands at the published `fraction`.
    static func make(
        runs: [CGRect], full: CGFloat?, sweep: LiveSweep, fraction: Double, monoNow: TimeInterval
    ) -> [Run] {
        let total = runs.reduce(0) { $0 + $1.width }
        var offsets: [CGFloat] = []
        var reached: CGFloat = 0
        for run in runs {
            offsets.append(reached)
            reached += run.width
        }
        // A run's share of a lit width laid along the whole line in reading
        // order: nothing before the edge reaches it, all of it once past.
        func share(_ lit: CGFloat, _ index: Int) -> CGFloat {
            min(max(lit - offsets[index], 0), runs[index].width)
        }
        guard total > 0 else { return runs.map { Run(rect: $0, start: 0, keys: []) } }
        guard let clock = sweep.clock, clock.rate > 0 else {
            let lit = KaraokeRenderer.litWidth(fraction: fraction, visible: total, full: full ?? total)
            return runs.indices.map { Run(rect: runs[$0], start: share(lit, $0), keys: []) }
        }

        // `litWidth` before its cap at the visible width: the run shares cap
        // it run by run, so the last run's end is where it stopped.
        let scale = max(full ?? total, total)
        func lit(_ song: TimeInterval) -> CGFloat {
            CGFloat(min(max(sweep.fraction(atSong: song), 0), 1)) * scale
        }
        let now = clock.position(at: monoNow)
        let stop = min(sweep.knots.last ?? now, clock.cap ?? .infinity)
        // The edge's path in song time: now, then every knot ahead up to the
        // end of the line or of the track. A word that takes no time jumps,
        // so its knot is two points, the width just before it and at it.
        var path: [(song: TimeInterval, lit: CGFloat)] = [(now, lit(now))]
        for knot in sweep.knots where knot > now && knot <= stop {
            let before = lit(knot - 1e-9), at = lit(knot)
            if abs(at - before) > 1e-6 { path.append((knot, before)) }
            path.append((knot, at))
        }
        if stop > now, (path.last?.song ?? now) < stop { path.append((stop, lit(stop))) }

        return runs.indices.map { index in
            let start = share(path[0].lit, index)
            guard path.count > 1 else { return Run(rect: runs[index], start: start, keys: []) }
            // Each run turns where the edge enters it and where it leaves, as
            // well as at the knots; between those it is a straight line too.
            let enters = offsets[index], leaves = offsets[index] + runs[index].width
            var points: [(song: TimeInterval, lit: CGFloat)] = [path[0]]
            for (from, to) in zip(path, path.dropFirst()) {
                if to.song > from.song, to.lit > from.lit {
                    for edge in [enters, leaves] where edge > from.lit && edge < to.lit {
                        let along = Double((edge - from.lit) / (to.lit - from.lit))
                        points.append((from.song + along * (to.song - from.song), edge))
                    }
                }
                points.append(to)
            }
            var keys: [Run.Key] = []
            for point in points {
                guard let mono = clock.mono(atSong: point.song) else { continue }
                let key = Run.Key(mono: mono, width: share(point.lit, index))
                // A run the edge has not reached, or has passed, is the same
                // width key after key; only the ends of a plateau are kept.
                if keys.count >= 2, keys[keys.count - 1].width == key.width, keys[keys.count - 2].width == key.width {
                    keys[keys.count - 1] = key
                } else {
                    keys.append(key)
                }
            }
            let moves = keys.contains { $0.width != start }
            return Run(rect: runs[index], start: start, keys: moves ? keys : [])
        }
    }
}

/// The sung line's bright copy, drawn once by SwiftUI in a layer of its own
/// and uncovered run by run by Core Animation, over the dim line SwiftUI
/// draws beneath it (`KaraokeText`).
struct KaraokeTrack: NSViewRepresentable {
    let input: KaraokeTrackView.Input
    let style: KaraokeTrackView.Style
    let line: AnyView

    /// False only where the line is drawn into a bitmap by a renderer that
    /// cannot draw a layer (`cacheDisplay`, `ImageRenderer`): the visual lab,
    /// which draws the sweep through `KaraokeRenderer` instead, as it does the
    /// marquee (`MarqueeTiming.travelsOnCoreAnimation`). The app never changes it.
    @MainActor static var drawsLayers = true

    /// The runs of the line SwiftUI laid out, in reading order, in the
    /// overlay's top-left space: the boxes `KaraokeRenderer` clips each run
    /// to, read from the same layout.
    static func runs(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [CGRect] {
        layouts.flatMap { anchored -> [CGRect] in
            let origin = proxy[anchored.origin]
            return anchored.layout.flatMap { $0 }.map { run in
                let bounds = run.typographicBounds
                return CGRect(
                    x: origin.x + bounds.origin.x, y: origin.y + bounds.origin.y - bounds.ascent,
                    width: bounds.width, height: bounds.ascent + bounds.descent
                )
            }
        }
    }

    func makeNSView(context: Context) -> KaraokeTrackView { KaraokeTrackView() }

    func updateNSView(_ view: KaraokeTrackView, context: Context) {
        // Handed the caller's environment, as the marquee's copies are, so the
        // bright copy is set in the line SwiftUI measured. The copy is drawn
        // again only when its style changes, so the parts of that environment
        // it is drawn with ride in the style too: a switch to Increase
        // Contrast would otherwise leave the sung half in the old colour.
        var style = style
        style.look = .init(context.environment)
        view.show(AnyView(line.environment(\.self, context.environment)), style: style)
        view.update(input)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KaraokeTrackView, context: Context) -> CGSize? {
        style.size
    }

    static func dismantleNSView(_ view: KaraokeTrackView, coordinator: ()) {
        view.stop()
    }
}

/// One layer-backed view: the bright copy in a hosting view, masked by one
/// bar per run whose width is the plan's animation, so the render server
/// moves the edge and the app's main thread is not woken between ticks.
final class KaraokeTrackView: NSView {
    struct Input: Equatable {
        var runs: [CGRect]
        var full: CGFloat?
        var sweep: LiveSweep
        var fraction: Double
    }

    /// What the bright copy looks like; it is drawn again only when this
    /// changes, not on every tick that hands the view a new reading.
    struct Style: Equatable {
        var text: String
        var font: Font
        var tracking: CGFloat
        var lineLimit: Int
        var accent: Color
        var size: CGSize
        var look: Look?
    }

    /// What the bright copy takes from the environment rather than from its
    /// caller.
    struct Look: Equatable {
        var scheme: ColorScheme
        var contrast: ColorSchemeContrast
        var direction: LayoutDirection
        var alignment: TextAlignment

        init(_ environment: EnvironmentValues) {
            scheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            direction = environment.layoutDirection
            alignment = environment.multilineTextAlignment
        }
    }

    static let sweepKey = "karaoke.sweep"

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let cover = CALayer()
    private var bars: [CALayer] = []
    /// Which bars were given an animation, so a lost one is noticed.
    private var animated: [Bool] = []
    /// How many times the bars were laid out, for the tests.
    private(set) var installs = 0
    /// The input the bars were last laid out for. Kept, not replaced by each
    /// tick's reading that agrees with it, so small corrections cannot add up
    /// unseen.
    private(set) var input: Input?
    private var style: Style?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(host)
        layer?.mask = cover
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Top-left, like the SwiftUI layout the runs come from.
    override var isFlipped: Bool { true }

    /// Clicks belong to the button the line sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// VoiceOver reads the line once, from the dim copy SwiftUI owns. The
    /// hosting view would otherwise offer the bright copy as a second
    /// element of the same words, which `accessibilityHidden` on the
    /// representable does not reach.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    func show(_ line: AnyView, style next: Style) {
        guard next != style else { return }
        style = next
        host.rootView = line
        needsLayout = true
    }

    func update(_ next: Input) {
        if let input, Self.same(input, next), isLive { return }
        input = next
        install()
    }

    func stop() {
        for bar in bars { bar.removeAnimation(forKey: Self.sweepKey) }
        input = nil
    }

    /// A tick used to hand the view its line ten times a second, and `update`
    /// re-laid a sweep that had lost its animation on the next one. The
    /// player's line is handed over only when it turns or the clock changes
    /// course since Batch 21, so a move into another window or onto another
    /// display, where AppKit can rebuild the layer, repairs it here instead,
    /// as `PlaybackFillView` does.
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

    func dropAnimationsForTests() {
        for bar in bars { bar.removeAnimation(forKey: Self.sweepKey) }
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.frame = bounds
        CATransaction.commit()
    }

    /// Whether `next` is the sweep already drawn: the same line in the same
    /// place, and either the same clock read again or, still, the same
    /// published fraction.
    static func same(_ drawn: Input, _ next: Input) -> Bool {
        guard drawn.runs == next.runs, drawn.full == next.full,
              drawn.sweep.words == next.sweep.words, drawn.sweep.end == next.sweep.end
        else { return false }
        switch (drawn.sweep.clock, next.sweep.clock) {
        case (nil, nil): return drawn.fraction == next.fraction
        case let (drawnClock?, nextClock?): return drawnClock.agrees(with: nextClock)
        default: return false
        }
    }

    /// The mask still on the layer and every animation still on its bar.
    /// AppKit can give a view a new layer, and a layer moved between trees
    /// can lose its animations; the next tick puts them back.
    private var isLive: Bool {
        guard layer?.mask === cover, bars.count == animated.count else { return false }
        return zip(bars, animated).allSatisfy { bar, wanted in !wanted || bar.animation(forKey: Self.sweepKey) != nil }
    }

    private func install() {
        guard let input else { return }
        if layer?.mask !== cover { layer?.mask = cover }
        let plan = KaraokePlan.make(
            runs: input.runs, full: input.full, sweep: input.sweep, fraction: input.fraction,
            monoNow: SongClock.hostNow()
        )
        installs += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while bars.count < plan.count {
            let bar = CALayer()
            bar.backgroundColor = CGColor(gray: 0, alpha: 1)
            bar.anchorPoint = .zero
            cover.addSublayer(bar)
            bars.append(bar)
        }
        while bars.count > plan.count { bars.removeLast().removeFromSuperlayer() }
        animated = []
        for (bar, run) in zip(bars, plan) {
            bar.removeAnimation(forKey: Self.sweepKey)
            bar.position = run.rect.origin
            bar.bounds = CGRect(x: 0, y: 0, width: run.start, height: run.rect.height)
            // A run's keys are moments on the media clock, which is Core
            // Animation's own (`KaraokeTrackTests`), so its first key is when
            // the animation begins — not a second reading of the clock taken
            // a little after the plan's.
            let begin = run.keys.first.map { layer?.convertTime($0.mono, from: nil) ?? $0.mono }
            let animation = begin.flatMap { run.animation(beginTime: $0) }
            if let animation { bar.add(animation, forKey: Self.sweepKey) }
            animated.append(animation != nil)
        }
        CATransaction.commit()
    }

    // For the tests.
    var barCount: Int { bars.count }
    var barFrames: [CGRect] { bars.map(\.frame) }
    var runningAnimation: CAAnimation? {
        bars.lazy.compactMap { $0.animation(forKey: Self.sweepKey) }.first
    }
}

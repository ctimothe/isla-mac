import AppKit
import QuartzCore
import SwiftUI

/// A line too long for its room scrolls, now and then, to show the rest of
/// itself: the player's "Title – Artist" (owner, 2026-10-18 — "Lover, You
/// Should've Come Over" was cut to "Lover, You Should've Come…" and Jeff
/// Buckley was not there at all).
///
/// The pattern is the one the iPod's Now Playing screen, tvOS's marquee text
/// style and car displays share: a line that fits is drawn as it is. One that
/// does not rests at its start, its far end faded rather than cut by an
/// ellipsis, then travels left at an even reading pace until a second copy, a
/// gap behind it, stands exactly where the first began, and rests again. The
/// jump back is to an identical picture, so the loop has no seam. While it
/// travels the near end fades too, so letters slide under both edges instead
/// of being cut.
///
/// The travel is Core Animation's, not SwiftUI's (Batch 11, 2026-10-29). It
/// was a SwiftUI offset animation, and SwiftUI animates on the main thread: every
/// frame of a pass laid out and re-rendered the whole panel, about 100 times a
/// second at 4–5 % of a core for as long as the player was open on a long
/// line, which with lyrics on is many songs, since the title line then
/// carries the artist. Rest and travel took 2.5 and about 8.5 s of every 11,
/// so it was most of the time (`Scripts/measure-idle-lab.sh`, the
/// `lyrics-arrive` state). Now the line is drawn once, by SwiftUI, and one
/// repeating animation in the render server moves it, rests it and fades its
/// near end, so a scrolling line costs the main thread nothing at all.
///
/// It never moves under Reduce Motion or while its page is not the one on
/// screen (`isActive` false); it then truncates with an ellipsis as it always
/// did. The whole line is the caller's tooltip and accessibility label either
/// way, and the moving copy is hidden from VoiceOver.
struct MarqueeLine<Content: View>: View {
    let room: CGFloat
    let isActive: Bool
    /// What the line says. A new value starts over from rest.
    let text: String
    @ViewBuilder let content: () -> Content

    /// How long the line rests at its start before each pass.
    static var rest: TimeInterval { MarqueeTiming.rest }
    /// The reading pace, points a second.
    static var speed: CGFloat { MarqueeTiming.speed }
    /// The space between the line and the copy that follows it.
    static var gap: CGFloat { MarqueeTiming.gap }
    /// The fade at each end.
    static var fade: CGFloat { MarqueeTiming.fade }

    /// Whether a line `contentWidth` wide scrolls in `room`; half a point of
    /// slack, so a line that measures a rounding over its room is not set
    /// moving for nothing.
    static func overflows(contentWidth: CGFloat, room: CGFloat) -> Bool { contentWidth > room + 0.5 }
    /// One pass: the line and its gap, so the copy lands where the line began.
    static func travel(contentWidth: CGFloat) -> CGFloat { MarqueeTiming.travel(contentWidth: contentWidth) }
    static func travelTime(contentWidth: CGFloat) -> TimeInterval { MarqueeTiming.travelTime(contentWidth: contentWidth) }

    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let scrolls = isActive && Self.overflows(contentWidth: contentWidth, room: room)
        // Above and below, every clip reaches past the line so an accent or a
        // descender is never cut.
        ZStack(alignment: .leading) {
            if scrolls && MarqueeTiming.travelsOnCoreAnimation {
                // The track masks itself: SwiftUI cannot mask a view of
                // AppKit's. VoiceOver reads the line once, as it read the
                // first copy before.
                MarqueeTrack(
                    run: MarqueeTrackView.Run(text: text, room: room, contentWidth: contentWidth),
                    content: copies(accessible: false)
                )
                .accessibilityRepresentation { content() }
                .allowsHitTesting(false)
            } else if scrolls {
                // The resting picture, drawn by SwiftUI, for a renderer that
                // cannot draw a layer (`travelsOnCoreAnimation`).
                copies(accessible: true)
                    .frame(width: room, alignment: .leading)
                    .mask { restingFade.padding(.vertical, -MarqueeTiming.maskOverhang) }
            } else {
                content()
                    .frame(width: room, alignment: .leading)
                    .mask { Color.black.padding(.vertical, -MarqueeTiming.maskOverhang) }
            }
        }
        .frame(width: room, alignment: .leading)
        .background(alignment: .leading) {
            content()
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
    }

    /// The line and the copy a gap behind it, which stands where the line
    /// began when a pass ends. The copy is never read.
    private func copies(accessible: Bool) -> some View {
        HStack(spacing: Self.gap) {
            content().fixedSize().accessibilityHidden(!accessible)
            content().fixedSize().accessibilityHidden(true)
        }
    }

    /// At rest the far end fades and the near end does not.
    private var restingFade: some View {
        HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fade)
        }
        .frame(width: room)
    }
}

/// The marquee's numbers, in one place for the SwiftUI view and the layer that
/// moves it.
enum MarqueeTiming {
    static let rest: TimeInterval = 2.5
    static let speed: CGFloat = 30
    static let gap: CGFloat = 32
    static let fade: CGFloat = 14
    /// How long the near end takes to fade in as a pass begins, and out once
    /// it ends.
    static let edgeFade: TimeInterval = 0.2
    /// How far the clip reaches above and below the line.
    static let maskOverhang: CGFloat = 6

    static func travel(contentWidth: CGFloat) -> CGFloat { contentWidth + gap }
    static func travelTime(contentWidth: CGFloat) -> TimeInterval { Double(travel(contentWidth: contentWidth) / speed) }

    /// False only where the line is drawn into a bitmap by a renderer that
    /// cannot draw a layer (`cacheDisplay`, `ImageRenderer`): the visual lab,
    /// which shows the line at rest. The app never changes it.
    @MainActor static var travelsOnCoreAnimation = true
}

/// The travelling line: SwiftUI draws it once, Core Animation moves it.
private struct MarqueeTrack<Copies: View>: NSViewRepresentable {
    let run: MarqueeTrackView.Run
    let content: Copies

    func makeNSView(context: Context) -> MarqueeTrackView { MarqueeTrackView() }

    func updateNSView(_ view: MarqueeTrackView, context: Context) {
        // The caller's font, tracking and colour reach the line through the
        // environment. SwiftUI carries it into a nested hosting view by
        // itself today; it is handed on here so the copies are always drawn
        // in the line SwiftUI measured, or the loop's jump back would show.
        view.show(AnyView(content.environment(\.self, context.environment)))
        view.start(run)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeTrackView, context: Context) -> CGSize? {
        CGSize(width: run.room, height: nsView.lineHeight)
    }

    static func dismantleNSView(_ view: MarqueeTrackView, coordinator: ()) {
        view.stop()
    }
}

/// One layer-backed view holding the drawn line. Its layer's mask carries the
/// fades and an inner strip's `sublayerTransform` the travel, both as one
/// repeating keyframe animation each, so the render server runs the whole
/// loop — rest, pass, jump back — and the app's main thread is not woken for
/// any of it.
///
/// The two are on different layers because a layer's mask moves with its
/// `sublayerTransform`. They were one layer in 0.4.0.20, and mid-pass the
/// clip slid left with the line it clipped: the title was drawn over the
/// cover and cut short inside its own room (owner, 2026-10-29). The outer
/// layer is never moved, so the clip stays where the room is.
final class MarqueeTrackView: NSView {
    struct Run: Equatable {
        var text: String
        var room: CGFloat
        var contentWidth: CGFloat
    }

    static let travelKey = "marquee.travel"
    static let fadeKey = "marquee.fade"

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    /// What travels: the two copies, inside the clip.
    private let strip = NSView()
    private let fade = CAGradientLayer()
    private(set) var run: Run?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        strip.wantsLayer = true
        addSubview(strip)
        strip.addSubview(host)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = Self.restingColors
        layer?.mask = fade
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Clicks belong to the button the line sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var lineHeight: CGFloat { host.fittingSize.height }
    /// The two copies and their gap as drawn: the caller's font reached them
    /// when this is twice the measured line and the gap.
    var drawnWidth: CGFloat { host.fittingSize.width }

    func show(_ line: AnyView) {
        host.rootView = line
        needsLayout = true
    }

    /// Starts the loop over from rest when what it shows, or where, changed.
    func start(_ next: Run) {
        guard next != run else { return }
        run = next
        needsLayout = true
        install()
    }

    func stop() {
        strip.layer?.removeAnimation(forKey: Self.travelKey)
        fade.removeAnimation(forKey: Self.fadeKey)
        run = nil
    }

    override func layout() {
        super.layout()
        let size = host.fittingSize
        strip.frame = bounds
        host.frame = CGRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds.insetBy(dx: 0, dy: -MarqueeTiming.maskOverhang)
        let edge = bounds.width > 0 ? min(MarqueeTiming.fade / bounds.width, 0.5) : 0
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }

    /// The mask's colours from the near end to the far: at rest the near end
    /// is solid, while a pass runs it fades like the far end.
    static let restingColors: [CGColor] = [solid, solid, solid, clear]
    static let travellingColors: [CGColor] = [clear, solid, solid, clear]
    private static let solid = CGColor(gray: 0, alpha: 1)
    private static let clear = CGColor(gray: 0, alpha: 0)

    /// The two animations for `run`, beginning one rest from now. Before they
    /// begin the layer shows its own values, which are the resting line, so
    /// the first rest needs no keyframes of its own; each cycle is a pass and
    /// then a rest, the order the SwiftUI loop ran them in.
    private func install() {
        guard let layer = strip.layer, let run else { return }
        layer.removeAnimation(forKey: Self.travelKey)
        fade.removeAnimation(forKey: Self.fadeKey)
        let animations = Self.animations(contentWidth: run.contentWidth)
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + MarqueeTiming.rest
        animations.travel.beginTime = begin
        animations.fade.beginTime = begin
        layer.add(animations.travel, forKey: Self.travelKey)
        fade.add(animations.fade, forKey: Self.fadeKey)
    }

    /// Pure, for the tests that hold the loop to the SwiftUI one it replaced:
    /// a linear pass of the line and its gap at 30 pt a second, a jump back to
    /// the identical picture, then the 2.5 s rest; the near end fades in over
    /// the pass's first 0.2 s and out over the rest's.
    static func animations(contentWidth: CGFloat) -> (travel: CAKeyframeAnimation, fade: CAKeyframeAnimation) {
        let distance = MarqueeTiming.travel(contentWidth: contentWidth)
        let pass = MarqueeTiming.travelTime(contentWidth: contentWidth)
        let cycle = pass + MarqueeTiming.rest
        let passEnd = NSNumber(value: pass / cycle)

        let travel = CAKeyframeAnimation(keyPath: "sublayerTransform.translation.x")
        travel.values = [0, -distance, 0, 0]
        travel.keyTimes = [0, passEnd, passEnd, 1]
        travel.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .linear), count: 3)

        let edge = MarqueeTiming.edgeFade
        let fade = CAKeyframeAnimation(keyPath: "colors")
        fade.values = [restingColors, travellingColors, travellingColors, restingColors, restingColors]
        fade.keyTimes = [0, NSNumber(value: edge / cycle), passEnd, NSNumber(value: (pass + edge) / cycle), 1]
        fade.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
        ]

        for animation in [travel, fade] {
            animation.duration = cycle
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = false
        }
        return (travel, fade)
    }
}

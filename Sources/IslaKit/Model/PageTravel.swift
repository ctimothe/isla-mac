import AppKit
import QuartzCore
import SwiftUI

/// The pages on their way from one to another (spec §19.16): under the
/// fingers, or settling after them, a dot or ⌃Tab. Nil at rest.
///
/// Its own object rather than more `@Published` on the view model: it changes
/// on every frame of a swipe, and only the open island's shell and its pages
/// draw from it. Everything else that watches the view model would be asked
/// to re-render sixty to a hundred and twenty times a second for nothing.
///
/// Every change is made with animations disabled. The pages are drawn exactly
/// where the fingers or the settle put them, frame by frame, and an implicit
/// `.animation` in the shell — the outline's spring on its height, the pane
/// swap — must never lay a curve of its own over them.
@MainActor
final class PageTravel: ObservableObject {
    typealias Surface = NotchViewModel.Surface

    struct Leg: Equatable {
        var strip: PageStrip
        /// Where the pages are drawn, along `strip`.
        var position: CGFloat
        /// The pages this leg can draw the outline at: one either side of
        /// where a swipe began, or the two a dot turns between. The clickable
        /// region covers all of them for the length of the leg, so it never
        /// has to be cut again mid-swipe.
        var reach: ClosedRange<Int>

        /// The pages with something on screen.
        var mounted: [Surface] { strip.mounted(at: position).map { strip.pages[$0] } }
        var reachable: [Surface] { reach.map { strip.pages[$0] } }
    }

    @Published private(set) var leg: Leg?
    /// Whether a leg is under way, published only when it changes: what the
    /// controller re-cuts the clickable region on.
    @Published private(set) var isTravelling = false
    private(set) var settle: PageSettle?
    var clock: PageClock

    init(clock: PageClock? = nil) {
        self.clock = clock ?? DisplayPageClock()
    }

    /// The fingers take the pages where they are: a settle under way stops
    /// where it is on screen.
    func grab(strip: PageStrip, position: CGFloat, reach: ClosedRange<Int>) {
        stopSettling()
        update(Leg(strip: strip, position: position, reach: reach))
    }

    func move(to position: CGFloat) {
        guard var leg else { return }
        leg.position = position
        update(leg)
    }

    /// Settles on page `target` of the leg's strip from where it is drawn,
    /// starting at `velocity` pages a second.
    func settle(to target: Int, velocity: CGFloat, reduceMotion: Bool) {
        guard let leg else { return }
        settle = PageSettle(
            from: leg.position, to: CGFloat(target), velocity: velocity, start: clock.now, reduceMotion: reduceMotion
        )
        clock.start { [weak self] in self?.step() }
    }

    /// Starts a leg between two pages that are not under the fingers — a dot,
    /// ⌃Tab — and settles it on the second.
    func turn(strip: PageStrip, from: Int, to target: Int, reduceMotion: Bool) {
        let position = leg?.strip == strip ? (leg?.position ?? CGFloat(from)) : CGFloat(from)
        grab(strip: strip, position: position, reach: min(from, target)...max(from, target))
        settle(to: target, velocity: 0, reduceMotion: reduceMotion)
    }

    /// One frame of a settle: the pages where the curve has them now, and the
    /// leg ended once they are at rest.
    func step() {
        guard let settle, var leg else { return finish() }
        let now = clock.now
        if settle.isDone(at: now) { return finish() }
        leg.position = settle.position(at: now)
        update(leg)
    }

    /// Puts the pages at rest at once: the settle came to an end, or
    /// something other than the pages took the panel (Settings, the stage,
    /// the panel closing).
    func finish() {
        stopSettling()
        update(nil)
    }

    private func stopSettling() {
        clock.stop()
        settle = nil
    }

    private func update(_ leg: Leg?) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            self.leg = leg
            if isTravelling != (leg != nil) { isTravelling = leg != nil }
        }
    }
}

/// What the pages settle on: one tick a frame while something moves, and the
/// time it is.
@MainActor
protocol PageClock: AnyObject {
    var now: TimeInterval { get }
    func start(_ tick: @escaping () -> Void)
    func stop()
}

/// The display's own clock: a display link from the island's view once the
/// controller hands one over, so each frame is drawn from the time it will be
/// shown at; until then, a 120 Hz timer.
@MainActor
final class DisplayPageClock: NSObject, PageClock {
    weak var view: NSView?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var tick: (() -> Void)?

    var now: TimeInterval { CACurrentMediaTime() }

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        guard link == nil, timer == nil else { return }
        if let view {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick?() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        tick?()
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }
}

/// How far the tray's strip is scrolled, written by the strip and read by the
/// swipe when a gesture begins. A plain reference, not `@Published`: nothing
/// is drawn from it.
@MainActor
final class ShelfStripPosition {
    var offset: CGFloat = 0
}

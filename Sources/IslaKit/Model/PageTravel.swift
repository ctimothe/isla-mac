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
        /// region covers all of them for the length of the leg, so it is cut
        /// again only when the reach itself changes.
        var reach: ClosedRange<Int>

        /// The pages with something on screen.
        var mounted: [Surface] { strip.mounted(at: position).map { strip.pages[$0] } }
        var reachable: [Surface] { reach.map { strip.pages[$0] } }

        /// Where the outline is drawn: `position`, held inside the reach. A
        /// rubber band past the page beside the one a swipe began on carries
        /// the content on, under resistance, but the outline stays that
        /// neighbour's size — mixed toward the page beyond, it grew outside the
        /// clickable region, which is cut for the reach alone (R8b review F4).
        var drawnPosition: CGFloat {
            min(max(position, CGFloat(reach.lowerBound)), CGFloat(reach.upperBound))
        }
    }

    @Published private(set) var leg: Leg?
    /// The pages the leg under way can reach — empty at rest — published only
    /// when they change: what the controller re-cuts the clickable region on.
    /// The reach, not merely whether a leg is under way: a swipe that catches
    /// a dot's travel can reach a page the dot's leg could not, and the region
    /// has to cover it too (R8b review F4).
    @Published private(set) var reachable: [Surface] = []
    private(set) var settle: PageSettle?
    /// The leg the pages set off on once the one under way reaches `via`
    /// (`aim(via:then:from:to:reduceMotion:)`); dropped by anything that
    /// takes the pages — fingers, another dot, the travel ending.
    private var onward: Onward?

    private struct Onward {
        var via: Int
        /// Where the pages were from `via` when it was set, by its sign: they
        /// have reached it once they are no longer on that side.
        var side: CGFloat
        var strip: PageStrip
        var from: Int
        var target: Int
        var reduceMotion: Bool
    }
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

    /// Sends the pages to `target` without the fingers — a dot, VoiceOver's
    /// increment, ⌃Tab — from `position` on `strip`. A settle already under
    /// way on the same strip is re-aimed at the speed it has on screen, so
    /// the change of mind is a bend in its path rather than a stop and a
    /// start.
    func aim(strip: PageStrip, from position: CGFloat, to target: Int, reduceMotion: Bool) {
        let velocity = leg?.strip == strip ? velocity : 0
        start(strip: strip, position: position, target: target, velocity: velocity, reduceMotion: reduceMotion)
    }

    /// Sends the leg under way on to a page its strip does not hold: `strip`
    /// is that strip with the page added at one end (`PageStrip.joining`), and
    /// `shift` how far that moved the pages already on it. They carry on from
    /// where they are on screen at the speed they have, as a re-aim on the
    /// same strip does (R8b review F5).
    func aim(onto strip: PageStrip, shift: CGFloat, to target: Int, reduceMotion: Bool) {
        guard let leg else { return }
        start(
            strip: strip, position: leg.position + shift, target: target, velocity: velocity,
            reduceMotion: reduceMotion
        )
    }

    /// Sends the leg under way to page `via` of its strip at the speed it
    /// has, and, as the pages reach it, on to `target` of `strip` — on which
    /// that page is `from` — at the speed they have then. For a page a leg
    /// cannot join without bending the row (`PageStrip.joining`). The pages
    /// set off the moment `via` is in place: every other page of the first
    /// strip is then wholly out of sight, and with `strip` holding only `via`
    /// and the new page, nothing lies beyond `via` on either, so the strip
    /// changes under it with nothing on screen moving (R8b re-review N2, P2).
    func aim(via: Int, then strip: PageStrip, from: Int, to target: Int, reduceMotion: Bool) {
        guard let leg else { return }
        start(strip: leg.strip, position: leg.position, target: via, velocity: velocity, reduceMotion: reduceMotion)
        onward = Onward(
            via: via, side: leg.position - CGFloat(via), strip: strip, from: from, target: target,
            reduceMotion: reduceMotion
        )
    }

    /// Pages a second the settle under way has on screen, or none at rest and
    /// under the fingers.
    var velocity: CGFloat { settle?.velocity(at: clock.now) ?? 0 }

    private func start(
        strip: PageStrip, position: CGFloat, target: Int, velocity: CGFloat, reduceMotion: Bool
    ) {
        let low = min(Int(position.rounded(.down)), target)
        let high = max(Int(position.rounded(.up)), target)
        grab(strip: strip, position: position, reach: max(0, low)...min(strip.lastIndex, high))
        settle(to: target, velocity: velocity, reduceMotion: reduceMotion)
    }

    /// One frame of a settle: the pages where the curve has them now, and the
    /// leg ended once they are at rest.
    func step() {
        guard let settle, var leg else { return finish() }
        let now = clock.now
        let done = settle.isDone(at: now)
        let position = done ? settle.to : settle.position(at: now)
        // Reaching `via` — crossing it, or coming to rest there — sets off on
        // the leg after it. What the pages carried past it this frame goes with
        // them, so they do not step back.
        if let onward, done || (position - CGFloat(onward.via)) * onward.side <= 0 {
            self.onward = nil
            return start(
                strip: onward.strip, position: CGFloat(onward.from) + position - CGFloat(onward.via),
                target: onward.target, velocity: done ? 0 : settle.velocity(at: now),
                reduceMotion: onward.reduceMotion
            )
        }
        if done { return finish() }
        leg.position = position
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
        onward = nil
    }

    private func update(_ leg: Leg?) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            self.leg = leg
            let reach = leg?.reachable ?? []
            if reachable != reach { reachable = reach }
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

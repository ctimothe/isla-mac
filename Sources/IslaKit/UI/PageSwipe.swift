import CoreGraphics
import Foundation
import SwiftUI

// MARK: - One scroll event

/// One scroll event as the pages read it (spec §19.16): the deltas in points,
/// both of AppKit's phases, whether the deltas are precise and when it came.
///
/// Precise deltas with phases are a trackpad's two fingers or a Magic Mouse's
/// one; a notched wheel has neither and never turns a page. The deltas are
/// AppKit's `scrollingDelta`, which already follow the owner's scrolling
/// direction: with natural scrolling, fingers moving left make `deltaX`
/// negative and move the content left, toward the later pages.
struct PageScroll: Equatable {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var phase: ScrollSample.Phase = .none
    var momentumPhase: ScrollSample.Phase = .none
    var precise: Bool = true
    var time: TimeInterval = 0
}

// MARK: - The pages side by side

/// Pages laid side by side, and where a position along them is.
///
/// A position is in pages: 1 is the second page at rest, 1.5 half way to the
/// third. Each page is centred on the outline at rest and the next one starts
/// where it ends, so the distance between two pages' resting places is half of
/// each width. Past either end the unit is the end page's own width, which is
/// what a rubber band is measured in.
struct PageStrip: Equatable {
    var pages: [NotchViewModel.Surface]
    var widths: [CGFloat]

    var lastIndex: Int { pages.count - 1 }

    /// Points between page `index`'s resting place and the next page's.
    func distance(after index: Int) -> CGFloat {
        (widths[index] + widths[index + 1]) / 2
    }

    /// Points from the first page's resting place to `position`.
    func offset(of position: CGFloat) -> CGFloat {
        if position <= 0 { return position * widths[0] }
        var total: CGFloat = 0
        for index in 0..<lastIndex {
            if position <= CGFloat(index + 1) {
                return total + (position - CGFloat(index)) * distance(after: index)
            }
            total += distance(after: index)
        }
        return total + (position - CGFloat(lastIndex)) * widths[lastIndex]
    }

    /// The position `offset` points from the first page's resting place.
    func position(at offset: CGFloat) -> CGFloat {
        if offset <= 0 { return offset / widths[0] }
        var total: CGFloat = 0
        for index in 0..<lastIndex {
            let distance = distance(after: index)
            if offset <= total + distance { return CGFloat(index) + (offset - total) / distance }
            total += distance
        }
        return CGFloat(lastIndex) + (offset - total) / widths[lastIndex]
    }

    /// Points of travel one page is worth at `position`: the distance between
    /// the two pages it lies between, or the end page's width past an end.
    func pointsPerPage(at position: CGFloat) -> CGFloat {
        if position < 0 { return widths[0] }
        if position >= CGFloat(lastIndex) { return widths[lastIndex] }
        return distance(after: Int(position.rounded(.down)))
    }

    /// The pages with something on screen at `position`: one at rest, the
    /// two either side of it on the way.
    func mounted(at position: CGFloat) -> [Int] {
        if position <= 0 { return [0] }
        if position >= CGFloat(lastIndex) { return [lastIndex] }
        let lower = Int(position.rounded(.down))
        return position == CGFloat(lower) ? [lower] : [lower, lower + 1]
    }

    /// Page `index`'s leading edge inside an outline `outlineWidth` wide, with
    /// the strip at `position`: centred at rest, and moved by exactly the
    /// travel since.
    func x(ofPage index: Int, at position: CGFloat, outlineWidth: CGFloat) -> CGFloat {
        (outlineWidth - widths[index]) / 2 + offset(of: CGFloat(index)) - offset(of: position)
    }

    /// How a page this strip does not hold joins a leg under way on it — a
    /// second dot during a straight leg (R8b review F5).
    enum Join: Equatable {
        /// The page goes at one end, and nothing on screen moves: `shift` is
        /// how far that moved the pages already on the strip along it — one
        /// when it went in front, none behind.
        case end(PageStrip, shift: CGFloat)
        /// The pages go to the strip's page `via` first, and on from there.
        case via(Int)
    }

    /// A page beyond either end in `row`'s order joins at that end. One that
    /// lies between two of the strip's pages cannot: at either end it would
    /// arrive from the wrong side of a neighbour, and the row only teaches
    /// where things are if it holds still (§19.16). The pages go by the nearer
    /// of the two instead (R8b re-review N2). So do pages fingers hold past
    /// either end: the rubber band is not a way toward a new page, and read as
    /// one it drew the page in where there had been nothing (re-review N3).
    /// Strips are kept in the row's order, which this relies on.
    func joining(
        _ page: NotchViewModel.Surface, width: CGFloat, row: [NotchViewModel.Surface], at position: CGFloat
    ) -> Join {
        if position < 0 { return .via(0) }
        if position > CGFloat(lastIndex) { return .via(lastIndex) }
        let place = row.firstIndex(of: page) ?? 0
        let places = pages.map { row.firstIndex(of: $0) ?? 0 }
        if place < places[0] {
            return .end(PageStrip(pages: [page] + pages, widths: [width] + widths), shift: 1)
        }
        if place > places[lastIndex] {
            return .end(PageStrip(pages: pages + [page], widths: widths + [width]), shift: 0)
        }
        let after = places.firstIndex { $0 > place } ?? lastIndex
        let before = after - 1
        return .via(position - CGFloat(before) <= CGFloat(after) - position ? before : after)
    }
}

// MARK: - The gesture

/// A sideways swipe over a page, from the fingers landing to their lifting
/// (spec §19.16). Pure: fed events and what is on screen, it answers whether
/// the event is the pages' and where the pages are. `NotchViewModel` drives
/// it and `PageTravel` draws what it says.
///
/// - The first 10 pt decide. More sideways than up or down pages; anything
///   else, and a gesture that began off the pages, is the page's for good —
///   Clipboard's list and Settings scroll as they always have.
/// - The tray's strip scrolls first: a gesture pages only if the strip was
///   already at its end, in the direction of travel, when it began.
/// - The content follows the fingers one to one, up to one page either side
///   of where the gesture began; past that, and past Music and Translate, it
///   rubber-bands.
/// - The release projects the velocity (Apple's deceleration, 0.998) and
///   chooses the page nearest the projection, one page away at most.
/// - The momentum macOS sends once the fingers lift is swallowed: the
///   projection has spent it, and under the pages it would scroll the strip.
struct PageSwipe: Equatable {
    static let lockDistance: CGFloat = 10
    static let rubberbandConstant: CGFloat = 0.55
    static let decelerationRate: CGFloat = 0.998
    /// How far back the release looks for the fingers' speed. A gesture whose
    /// fingers stopped this long before lifting throws nothing.
    static let velocityWindow: TimeInterval = 0.1

    /// The tray's strip, as it stood when a gesture began: whether it is
    /// scrolled to its first tile and to its last. Nil when it does not
    /// scroll, or the page is not the tray.
    struct StripEdge: Equatable {
        var atStart: Bool
        var atEnd: Bool
    }

    /// What the pages look like when an event arrives.
    struct Context: Equatable {
        var strip: PageStrip
        /// Where the pages are on screen: a page's index at rest, between two
        /// while one settles.
        var presented: CGFloat
        /// Whether the pointer is over the pages.
        var over: Bool
        var stripEdge: StripEdge?
    }

    enum Outcome: Equatable {
        /// Not the pages': hand the event on.
        case pass
        /// The pages' and nothing to move: the glide after a turn.
        case swallow
        /// Paging begins with the pages where they are on screen.
        case grab(position: CGFloat)
        case move(position: CGFloat)
        /// The fingers lifted: settle on `target` from `position`, starting at
        /// `velocity` pages a second.
        case release(target: Int, position: CGFloat, velocity: CGFloat)
    }

    enum Stage: Equatable {
        case idle
        case deciding
        case paging
        /// The page's, until the fingers lift.
        case refused
        /// A turn's fingers have lifted; its glide is swallowed until the
        /// next gesture lands.
        case released
        /// A dot or ⌃Tab took the pages from under the fingers: the rest of
        /// the gesture is swallowed, and its glide after it, rather than
        /// fighting the travel or turning somewhere else on release.
        case yielded
    }

    private struct Sample: Equatable {
        var time: TimeInterval
        var advance: CGFloat
    }

    private(set) var stage: Stage = .idle
    private var decided = CGSize.zero
    private var edgeAtBegin: StripEdge?
    private var strip: PageStrip?
    /// The page the gesture began on: it may go one page either side.
    private var anchor = 0
    /// Where the fingers would have the pages with no rubber band, in points
    /// from the first page.
    private var raw: CGFloat = 0
    private var samples: [Sample] = []

    mutating func handle(_ event: PageScroll, _ context: Context) -> Outcome {
        guard event.precise else { return .pass }
        if event.momentumPhase != .none {
            return stage == .released ? .swallow : .pass
        }
        switch event.phase {
        case .none:
            return .pass
        case .mayBegin:
            if stage == .released { stage = .idle }
            return .pass
        case .began:
            begin(context)
            return decide(event, context)
        case .changed:
            switch stage {
            case .deciding: return decide(event, context)
            case .paging: return .move(position: track(event))
            case .yielded: return .swallow
            case .idle, .refused, .released: return .pass
            }
        case .ended, .cancelled:
            switch stage {
            case .paging:
                _ = track(event)
                return release(at: event.time, thrown: event.phase == .ended)
            case .yielded:
                stage = .released
                return .swallow
            case .deciding, .refused:
                stage = .idle
                return .pass
            case .idle, .released:
                return .pass
            }
        }
    }

    /// The pages leave the fingers for a dot or ⌃Tab. Only a gesture that has
    /// the pages yields; one still deciding has passed every event to the
    /// page, and goes on deciding.
    mutating func yield() {
        if stage == .paging { stage = .yielded }
    }

    private mutating func begin(_ context: Context) {
        stage = context.over ? .deciding : .refused
        decided = .zero
        edgeAtBegin = context.stripEdge
        samples = []
    }

    private mutating func decide(_ event: PageScroll, _ context: Context) -> Outcome {
        guard stage == .deciding else { return .pass }
        decided.width += event.deltaX
        decided.height += event.deltaY
        samples.append(Sample(time: event.time, advance: -event.deltaX))
        guard hypot(decided.width, decided.height) >= Self.lockDistance else { return .pass }
        guard abs(decided.width) > abs(decided.height) else {
            stage = .refused
            return .pass
        }
        let towardLater = decided.width < 0
        if let edge = edgeAtBegin, !(towardLater ? edge.atEnd : edge.atStart) {
            stage = .refused
            return .pass
        }
        grab(context)
        return .grab(position: context.presented)
    }

    /// Takes the pages where they are on screen, so a gesture that lands
    /// while one settles picks it up without a jump — undoing the rubber band
    /// when it lands on one.
    private mutating func grab(_ context: Context) {
        let strip = context.strip
        self.strip = strip
        stage = .paging
        anchor = min(max(Int(context.presented.rounded()), 0), strip.lastIndex)
        let presented = strip.offset(of: context.presented)
        let (low, high) = bounds(strip)
        if presented > high.offset {
            raw = high.offset + Self.unband(presented - high.offset, dimension: strip.widths[high.index])
        } else if presented < low.offset {
            raw = low.offset - Self.unband(low.offset - presented, dimension: strip.widths[low.index])
        } else {
            raw = presented
        }
    }

    private func bounds(_ strip: PageStrip) -> (low: (index: Int, offset: CGFloat), high: (index: Int, offset: CGFloat)) {
        let low = max(0, anchor - 1)
        let high = min(strip.lastIndex, anchor + 1)
        return ((low, strip.offset(of: CGFloat(low))), (high, strip.offset(of: CGFloat(high))))
    }

    private mutating func track(_ event: PageScroll) -> CGFloat {
        raw -= event.deltaX
        samples.append(Sample(time: event.time, advance: -event.deltaX))
        return presentedPosition
    }

    /// Where the pages are drawn: the fingers' travel, rubber-banded past the
    /// pages the gesture may reach.
    private var presentedPosition: CGFloat {
        guard let strip else { return 0 }
        return strip.position(at: banded(raw, strip))
    }

    private func banded(_ raw: CGFloat, _ strip: PageStrip) -> CGFloat {
        let (low, high) = bounds(strip)
        if raw > high.offset {
            return high.offset + Self.rubberband(raw - high.offset, dimension: strip.widths[high.index])
        }
        if raw < low.offset {
            return low.offset - Self.rubberband(low.offset - raw, dimension: strip.widths[low.index])
        }
        return raw
    }

    private mutating func release(at time: TimeInterval, thrown: Bool) -> Outcome {
        guard let strip else { return .pass }
        stage = .released
        let fingers = thrown ? velocity(at: time) : 0
        let position = presentedPosition
        let projected = strip.position(at: raw + Self.projection(velocity: fingers))
        let (low, high) = bounds(strip)
        let target = min(max(Int(projected.rounded()), low.index), high.index)
        // What the content was doing, not the fingers: past an end it moved
        // less than they did, and the settle starts at the content's speed.
        let content = fingers * bandSlope(raw, strip)
        let velocity = content / strip.pointsPerPage(at: position)
        return .release(target: target, position: position, velocity: velocity)
    }

    /// How far the content moves for a point of the fingers' travel at `raw`.
    private func bandSlope(_ raw: CGFloat, _ strip: PageStrip) -> CGFloat {
        let (low, high) = bounds(strip)
        let constant = Self.rubberbandConstant
        func slope(_ overshoot: CGFloat, _ dimension: CGFloat) -> CGFloat {
            dimension * dimension * constant / pow(dimension + constant * overshoot, 2)
        }
        if raw > high.offset { return slope(raw - high.offset, strip.widths[high.index]) }
        if raw < low.offset { return slope(low.offset - raw, strip.widths[low.index]) }
        return 1
    }

    /// Points a second toward the later pages over the last `velocityWindow`
    /// before `time`: fingers that slowed or stopped before lifting carry
    /// that much less.
    private func velocity(at time: TimeInterval) -> CGFloat {
        let recent = samples.filter { time - $0.time <= Self.velocityWindow }
        return recent.reduce(0) { $0 + $1.advance } / Self.velocityWindow
    }

    // MARK: Shared formulas

    /// The apple-design rubber band: the further past the bound, the less the
    /// content follows.
    static func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = rubberbandConstant) -> CGFloat {
        overshoot * dimension * constant / (dimension + constant * abs(overshoot))
    }

    /// The overshoot that bands to `banded`: how a gesture landing on a rubber
    /// band takes it up where it is.
    static func unband(_ banded: CGFloat, dimension: CGFloat, constant: CGFloat = rubberbandConstant) -> CGFloat {
        let limit = dimension * 0.999
        let banded = min(banded, limit)
        return banded * dimension / (constant * (dimension - banded))
    }

    /// Where a flick at `velocity` points a second comes to rest, decelerating
    /// as a scroll view does (Designing Fluid Interfaces).
    static func projection(velocity: CGFloat) -> CGFloat {
        velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }
}

// MARK: - The settle

/// A page coming to rest after a release, a dot or ⌃Tab: on the island's
/// spring from where it is and as fast as it was going, or under Reduce Motion
/// the 0.24 ease-in-out with nothing past the page (spec §19.16, §19.3).
/// Pure: a position for any moment, so the pages can be drawn — and caught —
/// exactly where the curve has them.
struct PageSettle: Equatable {
    var from: CGFloat
    var to: CGFloat
    /// Pages a second at the start.
    var velocity: CGFloat
    var start: TimeInterval
    var reduceMotion: Bool

    static let spring = Spring(response: Theme.islandResponse, dampingRatio: Theme.islandDamping)
    /// A thousandth of a page — half a point on the widest — is at rest.
    static let restingDistance: Double = 0.001

    func position(at time: TimeInterval) -> CGFloat {
        let elapsed = max(0, time - start)
        if isDone(at: time) { return to }
        if reduceMotion {
            let progress = UnitCurve.easeInOut.value(at: elapsed / Theme.reducedMotionDuration)
            return from + (to - from) * progress
        }
        let change = Self.spring.value(
            target: Double(to - from), initialVelocity: Double(velocity), time: elapsed
        )
        return from + CGFloat(change)
    }

    /// Pages a second at `time`: what a settle re-aimed mid-way starts from.
    func velocity(at time: TimeInterval) -> CGFloat {
        guard !reduceMotion, !isDone(at: time) else { return 0 }
        let elapsed = max(0, time - start)
        return CGFloat(Self.spring.velocity(
            target: Double(to - from), initialVelocity: Double(velocity), time: elapsed
        ))
    }

    func isDone(at time: TimeInterval) -> Bool {
        let elapsed = time - start
        if reduceMotion { return elapsed >= Theme.reducedMotionDuration }
        let duration = Self.spring.settlingDuration(
            target: Double(to - from), initialVelocity: Double(velocity), epsilon: Self.restingDistance
        )
        return elapsed >= duration
    }
}

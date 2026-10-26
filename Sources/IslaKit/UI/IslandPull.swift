import CoreGraphics
import Foundation
import SwiftUI

/// Two fingers down over the shut island open it; two fingers up on the open
/// panel's header put it back to the shut island (owner, 2026-10-25: "when I
/// swipe two fingers down the island should be shown, and when I swipe up it
/// should close to the default unclicked state"). Pure, the way `PageSwipe`
/// and `LyricFollowGate` are: fed events and where the pointer is, it answers
/// whether the event is the pull's and what the panel should do. The
/// controller's scroll monitor feeds it and acts; `IslandPullStretch` draws it.
///
/// Nothing in macOS is bound to a two-finger vertical swipe — Mission Control
/// and App Exposé are three or four fingers, Notification Center is two
/// fingers sliding leftward in from the trackpad's right edge — and a scroll
/// event reaches a window only under the pointer, so the pull is heard only
/// where the island's own hit region is: everywhere else it is the app
/// underneath's ordinary scroll, untouched.
///
/// - **Precise scrolls only.** A trackpad's two fingers or a Magic Mouse's
///   one; a notched wheel has no phases, so no gesture has a beginning to
///   start over the island or an end to commit on, and a wheel turned while
///   the pointer drifted under the menu bar — scrolling a page near the top
///   of the screen — would have popped the panel open with nothing to say it
///   was meant. The wheel has the click.
/// - **The first 10 pt decide**, as `PageSwipe`'s do, and with the opposite
///   rule: more up or down than sideways is the pull's, more sideways is the
///   pages'. The two cannot both claim one gesture, so neither needs to know
///   the other exists.
/// - **It starts where it may.** Shut: the island and the Shelf's bubble, for
///   down. Open: the header row on every surface, and the whole player, for
///   up — nothing on the player scrolls vertically. Anywhere else a vertical
///   scroll is the reader's: the Shelf's grid, Clipboard's list, the lyric
///   stage (`LyricFollowGate`), Settings' form, Translate's text. A gesture
///   that began anywhere else is never the pull's, however it goes on.
/// - **The release commits**, never the middle: the fingers' travel plus the
///   projection of their speed (Apple's deceleration, as the pages throw)
///   must reach `commitDistance`. A pull taken back before lifting, held
///   still short of it, or cancelled settles back with nothing done.
/// - **Momentum never acts.** The glide macOS sends after a lift is swallowed
///   when it is a pull's (it would scroll the page that just opened under it)
///   and handed on otherwise — so the tail of a flick through Clipboard's
///   list that reaches the header never closes the panel.
/// - **Over the lock screen** a pull down is refused the way a click is: the
///   shake on release, and no stretch toward an open that cannot happen.
struct IslandPull: Equatable {
    typealias Surface = NotchViewModel.Surface

    static let lockDistance: CGFloat = PageSwipe.lockDistance
    /// The fingers' projected travel a release must reach. A third of the
    /// player's header row past the lock: far enough that a pull begun by
    /// accident and stopped is not an open, near enough that a short flick is.
    static let commitDistance: CGFloat = 32
    /// What the outline is drawn longer (or, closing, shorter) by while the
    /// fingers track, as an asymptote: the rubber band never reaches it. A
    /// hint that the island is listening, not a drag of the panel — the
    /// window is cut once and never resized, and the content does not move.
    static let stretchLimit: CGFloat = 8
    static let velocityWindow: TimeInterval = PageSwipe.velocityWindow

    /// Where the gesture's began landed.
    enum Region: Equatable {
        /// Not on any part of the panel that takes events.
        case outside
        /// The shut island's hit region (`NotchRootView.activeRect` while shut).
        case island
        /// The Shelf's bubble beside it (`NotchRootView.bubbleRect`).
        case bubble
        /// The open panel's header row: the top `notchHeight` of the body.
        case header
        /// The open panel below the header.
        case body
    }

    struct Context: Equatable {
        /// Swipe to Open and Close, in Settings.
        var enabled: Bool = true
        var isOpen: Bool
        var locked: Bool = false
        var region: Region
        /// What the open panel presents.
        var surface: Surface = .player
        /// The pages are travelling between two: a swipe or a dot is under
        /// way, and the outline is the travel's to draw.
        var travelling: Bool = false
    }

    enum Outcome: Equatable {
        /// Not the pull's: hand the event on.
        case pass
        /// The pull's, with nothing to draw: the glide after a release.
        case swallow
        /// The pull's: draw the outline this many points longer (negative:
        /// shorter) than it is.
        case stretch(CGFloat)
        /// Open on `surface`, or on what a click on the island opens when nil.
        case open(Surface?)
        case close
        /// Over the shield: the click's refusal.
        case refuse
        /// Released short: the stretch goes back, nothing else happens.
        case settle
    }

    enum Stage: Equatable {
        case idle
        case deciding
        case pulling
        /// Not the pull's, until the fingers lift.
        case refused
        /// The pull's fingers have lifted; its glide is swallowed until the
        /// next gesture lands.
        case released
    }

    /// What the gesture would do if it committed, chosen when it lands.
    private enum Aim: Equatable {
        case open(Surface?)
        case close
        case refuse
    }

    private struct Sample: Equatable {
        var time: TimeInterval
        var progress: CGFloat
    }

    private(set) var stage: Stage = .idle
    private var aim: Aim = .close
    private var decided = CGSize.zero
    /// The fingers' travel toward the aim since the began: down to open, up
    /// to close. Negative once they have gone back past where they landed.
    private var progress: CGFloat = 0
    private var samples: [Sample] = []

    /// The fingers' travel toward the bottom of the trackpad in this event.
    /// AppKit's deltas follow the content: with natural scrolling fingers
    /// moving down make `deltaY` positive, with it off negative.
    static func fingersDown(_ event: PageScroll) -> CGFloat {
        event.invertedFromDevice ? event.deltaY : -event.deltaY
    }

    /// Whether an up-swipe anywhere on `surface`'s body closes the panel, not
    /// just on its header. Only the player: it is the one surface with
    /// nothing that scrolls vertically, and every other one has a list, a
    /// grid, a form, lines or text that an up-swipe is reading.
    static func closesFromBody(_ surface: Surface) -> Bool {
        surface == .player
    }

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
            return decide(event)
        case .changed:
            switch stage {
            case .deciding: return decide(event)
            case .pulling: return .stretch(track(event))
            case .idle, .refused, .released: return .pass
            }
        case .ended, .cancelled:
            switch stage {
            case .pulling:
                return release(at: event.time, committed: event.phase == .ended)
            case .deciding, .refused:
                stage = .idle
                return .pass
            case .idle, .released:
                return .pass
            }
        }
    }

    private mutating func begin(_ context: Context) {
        decided = .zero
        progress = 0
        samples = []
        stage = .refused
        guard context.enabled, !context.travelling, let aim = Self.aim(for: context) else { return }
        self.aim = aim
        stage = .deciding
    }

    private static func aim(for context: Context) -> Aim? {
        if context.isOpen {
            guard !context.locked else { return nil }
            switch context.region {
            case .header: return .close
            case .body: return closesFromBody(context.surface) ? .close : nil
            case .outside, .island, .bubble: return nil
            }
        }
        switch context.region {
        case .island: return context.locked ? .refuse : .open(nil)
        case .bubble: return context.locked ? .refuse : .open(.tray)
        case .outside, .header, .body: return nil
        }
    }

    private mutating func decide(_ event: PageScroll) -> Outcome {
        guard stage == .deciding else { return .pass }
        decided.width += event.deltaX
        decided.height += event.deltaY
        let step = toward(event)
        progress += step
        samples.append(Sample(time: event.time, progress: step))
        guard hypot(decided.width, decided.height) >= Self.lockDistance else { return .pass }
        guard abs(decided.height) > abs(decided.width), progress > 0 else {
            stage = .refused
            return .pass
        }
        stage = .pulling
        return .stretch(stretch)
    }

    /// This event's travel toward what the gesture aims at.
    private func toward(_ event: PageScroll) -> CGFloat {
        let down = Self.fingersDown(event)
        return aim == .close ? -down : down
    }

    private mutating func track(_ event: PageScroll) -> CGFloat {
        let step = toward(event)
        progress += step
        samples.append(Sample(time: event.time, progress: step))
        return stretch
    }

    /// The outline's give: the rubber band of the travel, toward the aim's
    /// side — longer when pulled open, shorter when pushed shut, and none
    /// over the shield, where nothing is going to open.
    private var stretch: CGFloat {
        guard aim != .refuse else { return 0 }
        let banded = PageSwipe.rubberband(max(0, progress), dimension: Self.stretchLimit)
        return aim == .close ? -banded : banded
    }

    private mutating func release(at time: TimeInterval, committed: Bool) -> Outcome {
        stage = .released
        guard committed else { return .settle }
        let recent = samples.filter { time - $0.time <= Self.velocityWindow }
        let velocity = recent.reduce(0) { $0 + $1.progress } / Self.velocityWindow
        guard progress + PageSwipe.projection(velocity: velocity) >= Self.commitDistance else { return .settle }
        switch aim {
        case .open(let surface): return .open(surface)
        case .close: return .close
        case .refuse: return .refuse
        }
    }
}

/// How far the pull has the outline drawn past its size, in points: longer
/// pulled open, shorter pushed shut (`IslandPull.Outcome.stretch`). An object
/// of its own, as `PageTravel` is, so a frame of tracking publishes one number
/// rather than the whole view model. Only the outline reads it — the content,
/// the hit region and the window keep their sizes — and under Reduce Motion
/// it stays at zero: the gesture still opens and closes, on the curves the
/// click already uses there.
@MainActor
final class IslandPullStretch: ObservableObject {
    @Published private(set) var points: CGFloat = 0

    /// Follows the fingers: no curve, the layers take it as it comes.
    func track(_ points: CGFloat) {
        guard points != self.points else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.points = points }
    }

    /// Back to the outline's own size on the island's spring — the curve the
    /// open and the close it may go with are already on.
    func settle(reduceMotion: Bool) {
        guard points != 0 else { return }
        withAnimation(Theme.island(reduceMotion: reduceMotion)) { points = 0 }
    }
}

import CoreGraphics
import Foundation

/// One scroll event, as the lyric stage's follow gate wants it: the distances
/// and the two phases, with `NSEvent` left at the door so the decision below is
/// something a test can drive with plain numbers.
struct ScrollSample: Equatable {
    /// A trackpad gesture's phase, or a wheel's lack of one. `NSEvent.Phase` is
    /// an option set that AppKit fills in two fields (`phase` for the fingers,
    /// `momentumPhase` for the glide after them); this keeps the one distinction
    /// the gate needs from each.
    enum Phase: Equatable {
        /// No phase: a mouse wheel, or the phase that is not the one running.
        case none
        /// The fingers have touched but nothing has moved yet.
        case mayBegin
        case began
        case changed
        case ended
        case cancelled
    }

    /// Points of travel, positive down for `deltaY`, already scaled from lines
    /// for a notched wheel (`ScrollWheelWatch` does the scaling).
    var deltaX: CGFloat
    var deltaY: CGFloat
    var phase: Phase = .none
    var momentumPhase: Phase = .none

    /// The tail of a flick, after the fingers have gone.
    var isMomentum: Bool { momentumPhase != .none }
}

/// Decides when a scroll on the lyric stage means "I am reading, not watching",
/// and when the page should go back to the song by itself.
///
/// The stage used to stop following on *any* nonzero scroll event anywhere over
/// the panel while it was on screen — a sideways swipe, a one-pixel brush of a
/// trackpad on the way to something else — and never started again unless the
/// reader found the Sync pill (which only appears once the sung line has left
/// the stage) or tapped a line. A slip of the hand cost the song (owner,
/// 2026-10-16: "when I just swipe a little, even by mistake, I'm losing the
/// track on synchronization"). The rules now:
///
/// 1. **Only over the stage.** The caller says whether the pointer is over the
///    lyric stage; an event elsewhere decides nothing, and touches no state.
/// 2. **Mostly horizontal is not reading.** `|deltaX| > |deltaY|` is ignored.
/// 3. **Distance, not a touch.** Vertical travel adds up per gesture, and the
///    page stops following only once a gesture has gone `stopDistance` points.
///    A gesture begins on the trackpad's `began` phase or after `gestureGap`
///    seconds of silence; the inertial tail of a flick is the same gesture.
/// 4. **It comes back by itself.** Once not following, the page follows again
///    `resumeDelay` seconds after the last scroll event, momentum included, and
///    each new scroll starts that wait again. Tapping a line, the Sync pill and
///    Sync Here still put it back at once; those call `reset()`.
///
/// "Do not force it by overriding" (owner): nothing here moves the page while a
/// hand is on it. A gesture too short to stop following still scrolls the page
/// a little — the scroll view does that on its own — and `settle` is the one
/// moment the stage puts it back, `gestureGap` after the hand has gone.
///
/// A value, with the clock handed in on every call: nothing in it knows what
/// time it is, so the tests set it.
struct LyricFollowGate: Equatable {
    /// How far one gesture must travel before the page stops following: about
    /// half a row on the tall page, the least that is plainly a reader's scroll
    /// and never a brush.
    static let stopDistance: CGFloat = 12
    /// Silence after which the next event is a new gesture.
    static let gestureGap: TimeInterval = 0.5
    /// How long the page waits, after the last scroll event, before it follows
    /// the song again.
    static let resumeDelay: TimeInterval = 4
    /// What one line of a notched wheel is worth in points. A click of a mouse
    /// wheel is deliberate — nobody brushes one by accident — so a single
    /// notch reaches the stop distance by itself.
    static let wheelLinePoints: CGFloat = 12

    /// What the stage does with an event.
    enum Decision: Equatable {
        /// Not a reader's scroll: elsewhere, sideways, or no distance at all.
        case ignored
        /// A vertical scroll that has not gone far enough to stop following.
        case nudged
        /// This event took the gesture past the stop distance: stop following.
        case stoppedFollowing
        /// Already reading; the wait to resume starts again.
        case kept
    }

    private(set) var travelled: CGFloat = 0
    /// The last vertical event over the stage, for the gesture boundary and
    /// for the settle that follows a nudge.
    private(set) var lastEventAt: TimeInterval?

    /// Feeds one event to the gate. `following` is the stage's own state, which
    /// is not kept here: the tap, the Sync pill and Sync Here all change it from
    /// outside and would otherwise have to tell two places.
    mutating func handle(
        _ sample: ScrollSample, overStage: Bool, following: Bool, at now: TimeInterval
    ) -> Decision {
        guard overStage else { return .ignored }
        // The start of a gesture clears the tally even when it carries no
        // distance yet — those are the events that open every trackpad phase.
        if sample.phase == .began { travelled = 0 }
        guard sample.deltaY != 0, abs(sample.deltaX) <= abs(sample.deltaY) else { return .ignored }
        if !sample.isMomentum, let last = lastEventAt, now - last > Self.gestureGap {
            travelled = 0
        }
        lastEventAt = now
        travelled += abs(sample.deltaY)
        guard following else { return .kept }
        return travelled >= Self.stopDistance ? .stoppedFollowing : .nudged
    }

    /// Seconds until the stage should put the page back, or nil when nothing is
    /// waiting. Zero or less means now.
    ///
    /// Not following: `resumeDelay` after the last event. Following, after a
    /// gesture too short to stop it: `gestureGap` after the last event, so a
    /// brush that moved the page a few points does not leave it there until the
    /// next line.
    func settleIn(following: Bool, at now: TimeInterval) -> TimeInterval? {
        guard let lastEventAt else { return nil }
        let wait = following ? Self.gestureGap : Self.resumeDelay
        return lastEventAt + wait - now
    }

    /// The page is following and centred: nothing is waiting any more. Called
    /// when the stage resumes for any reason, and when it goes.
    mutating func reset() {
        travelled = 0
        lastEventAt = nil
    }
}

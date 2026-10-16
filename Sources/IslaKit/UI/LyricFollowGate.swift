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
/// and when the page should go back to the song.
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
///    lyric stage; an event elsewhere decides nothing.
/// 2. **Mostly horizontal is not reading.** `|deltaX| > |deltaY|` is ignored.
/// 3. **Distance, not a touch.** Vertical travel adds up per gesture, and the
///    page stops following only once a gesture has gone `stopDistance` points.
///    A trackpad gesture is *live* from its `began` phase until the fingers
///    lift (`ended`/`cancelled`) and any momentum after them has ended; the tally
///    never resets while it is live, however slowly the reader moves — a
///    trackpad sends no events while the fingers rest, and reading a verse
///    6 pt, pause, 6 pt is still one gesture. A mouse wheel has no phases, so
///    it keeps the silence rule: a new gesture after `gestureGap` seconds.
/// 4. **It comes back by itself, when it is not in the way.** Once not
///    following, the page follows again once `resumeDelay` seconds have passed
///    since the last scroll event, momentum included, the gesture is over *and
///    the pointer is not over the stage* — a reader whose pointer is still
///    resting on the verse is not pulled away ("do not force it", owner). It is
///    asked again every `pointerRecheck` seconds. Tapping a line, the Sync pill
///    and Sync Here still put it back at once; those call `reset()`.
///
/// Nothing here moves the page while a hand is on it. A gesture too short to
/// stop following still scrolls the page a little — the scroll view does that
/// on its own — and the page is put back only once the gesture is over
/// (`settle` says `.recentre`), and the stage holds its line-follow centring
/// back for as long as one is live (`isLive`).
///
/// A value, with the clock and the pointer handed in: nothing in it knows what
/// time it is or where the pointer is, so the tests set both.
struct LyricFollowGate: Equatable {
    /// How far one gesture must travel before the page stops following: about
    /// half a row on the tall page, the least that is plainly a reader's scroll
    /// and never a brush.
    static let stopDistance: CGFloat = 12
    /// Silence after which a wheel's next event is a new gesture, and after
    /// which a finished gesture's page is put back.
    static let gestureGap: TimeInterval = 0.5
    /// How long after the last scroll event the page may follow the song again.
    static let resumeDelay: TimeInterval = 4
    /// How often a due resume asks again while the pointer is over the stage.
    static let pointerRecheck: TimeInterval = 1
    /// How often a live gesture is asked whether it is over.
    static let liveRecheck: TimeInterval = 0.25
    /// A live gesture silent for this long is taken to have lost its end event
    /// (a view that went mid-gesture, a window that took the event): it stops
    /// holding the page back. Resting fingers send nothing, so this is long.
    static let liveTimeout: TimeInterval = 15
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

    /// What the stage does when its wait is up.
    enum Settle: Equatable {
        /// Nothing is waiting.
        case none
        /// Ask again after this many seconds.
        case wait(TimeInterval)
        /// A brush moved the page and is over: put it back on the sung line.
        case recentre
        /// The reader has gone quiet and the pointer is away: follow again.
        case resume
    }

    private(set) var travelled: CGFloat = 0
    /// The last counted vertical event, for the gesture boundary and the waits.
    private(set) var lastEventAt: TimeInterval?
    /// Fingers on the trackpad since a counted `began`/`changed`, until
    /// `ended`/`cancelled`.
    private var fingersDown = false
    /// A counted momentum event has arrived and its end has not.
    private var momentumLive = false

    /// Whether a trackpad gesture is in progress: fingers down, or the glide
    /// after them. Always false for a mouse wheel.
    func isLive(at now: TimeInterval) -> Bool {
        guard fingersDown || momentumLive, let lastEventAt else { return false }
        return now - lastEventAt <= Self.liveTimeout
    }

    /// Feeds one event to the gate. `following` is the stage's own state, which
    /// is not kept here: the tap, the Sync pill and Sync Here all change it from
    /// outside and would otherwise have to tell two places.
    mutating func handle(
        _ sample: ScrollSample, overStage: Bool, following: Bool, at now: TimeInterval
    ) -> Decision {
        // A gesture's end is bookkeeping for one already live, and arrives
        // wherever the pointer has wandered to; it is never refused.
        if sample.phase == .ended || sample.phase == .cancelled { fingersDown = false }
        if sample.momentumPhase == .ended || sample.momentumPhase == .cancelled { momentumLive = false }
        guard overStage else { return .ignored }
        // The start of a gesture clears the tally even when it carries no
        // distance yet — those are the events that open every trackpad phase.
        if sample.phase == .began { travelled = 0 }
        guard sample.deltaY != 0, abs(sample.deltaX) <= abs(sample.deltaY) else { return .ignored }
        // Silence starts a new gesture only between gestures: not while fingers
        // are down or a glide is running, and never for the glide itself.
        if !isLive(at: now), !sample.isMomentum, let last = lastEventAt, now - last > Self.gestureGap {
            travelled = 0
        }
        lastEventAt = now
        travelled += abs(sample.deltaY)
        if sample.phase == .began || sample.phase == .changed { fingersDown = true }
        if sample.momentumPhase == .began || sample.momentumPhase == .changed { momentumLive = true }
        guard following else { return .kept }
        return travelled >= Self.stopDistance ? .stoppedFollowing : .nudged
    }

    /// What the stage should do about the page now.
    ///
    /// While a gesture is live nothing is due: the stage asks again shortly.
    /// Following, after a gesture too short to stop it: put the page back
    /// `gestureGap` after it is over. Not following: follow again `resumeDelay`
    /// after the last event — but only while `pointerOverStage()` is false, and
    /// asked again every `pointerRecheck` seconds while it is true, so the page
    /// returns as soon as the pointer leaves. The pointer is a closure so it is
    /// asked only when the answer matters.
    func settle(following: Bool, pointerOverStage: () -> Bool, at now: TimeInterval) -> Settle {
        guard let lastEventAt else { return .none }
        if isLive(at: now) { return .wait(Self.liveRecheck) }
        let due = lastEventAt + (following ? Self.gestureGap : Self.resumeDelay)
        if now < due { return .wait(due - now) }
        if following { return .recentre }
        return pointerOverStage() ? .wait(Self.pointerRecheck) : .resume
    }

    /// The page is following and centred: nothing is waiting any more. Called
    /// when the stage resumes for any reason, and when it goes.
    mutating func reset() {
        self = LyricFollowGate()
    }
}

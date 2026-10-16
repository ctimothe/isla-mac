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
    /// (a view that went mid-gesture, a window that took the event) — but only
    /// once the pointer has left the stage, because resting fingers send nothing
    /// and look the same.
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
        /// Two fingers laid on the stage (`mayBegin`, or a `began` with no
        /// distance yet): no travel to count, but the page is being held.
        case held
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
    /// The last counted vertical event, for the tally's silence rule.
    private(set) var lastEventAt: TimeInterval?
    /// The last moment anything happened to the gesture: a counted event, two
    /// fingers laid down, or the fingers or the glide ending. Every wait is
    /// measured from here, so a hand that rests and then lifts is timed from
    /// the lift, not from its last movement.
    private(set) var touchedAt: TimeInterval?
    /// Fingers on the trackpad since `mayBegin`/`began`/`changed` over the
    /// stage, until `ended`/`cancelled`.
    private var fingersDown = false
    /// A counted momentum event has arrived and its end has not.
    private var momentumLive = false
    /// The last counted event carried no phase at all: a notched wheel, or a
    /// smooth-scroll utility or mouse driver sending fine-grained deltas with
    /// none. It is live for `gestureGap` after each event, since nothing else
    /// says when it is over.
    private var phaseless = false

    /// Whether a gesture is in progress, so the page is not to be moved: fingers
    /// down or a glide running (a trackpad), or, with no phases to go by, an
    /// event within `gestureGap`.
    ///
    /// A trackpad sends nothing while the fingers rest, which looks exactly like
    /// a gesture whose end was lost. So a silent gesture is let go of after
    /// `liveTimeout` only when the pointer has left the stage; while it is still
    /// over it, the hand is taken to be resting there and the gesture stays live.
    func isLive(at now: TimeInterval, pointerOverStage: () -> Bool) -> Bool {
        guard let touchedAt else { return false }
        if fingersDown || momentumLive {
            return now - touchedAt <= Self.liveTimeout || pointerOverStage()
        }
        guard phaseless, let lastEventAt else { return false }
        return now - lastEventAt < Self.gestureGap
    }

    /// Feeds one event to the gate. `following` is the stage's own state, which
    /// is not kept here: the tap, the Sync pill and Sync Here all change it from
    /// outside and would otherwise have to tell two places.
    mutating func handle(
        _ sample: ScrollSample, overStage: Bool, following: Bool, at now: TimeInterval
    ) -> Decision {
        // A gesture's end is bookkeeping for one already live, and arrives
        // wherever the pointer has wandered to; it is never refused.
        if sample.phase == .ended || sample.phase == .cancelled {
            if fingersDown { touchedAt = now }
            fingersDown = false
        }
        if sample.momentumPhase == .ended || sample.momentumPhase == .cancelled {
            if momentumLive { touchedAt = now }
            momentumLive = false
        }
        guard overStage else { return .ignored }
        // Two fingers laid on the pad hold the page before they move: the
        // natural way to keep it where it is. That is live whatever the delta.
        let holds = sample.phase == .mayBegin || sample.phase == .began
        if holds {
            fingersDown = true
            touchedAt = now
        }
        // The start of a gesture clears the tally even when it carries no
        // distance yet — those are the events that open every trackpad phase.
        if sample.phase == .began { travelled = 0 }
        guard sample.deltaY != 0, abs(sample.deltaX) <= abs(sample.deltaY) else {
            return holds ? .held : .ignored
        }
        // Silence starts a new gesture only between gestures: not while fingers
        // are down or a glide is running, and never for the glide itself.
        if !isLive(at: now, pointerOverStage: { true }), !sample.isMomentum,
           let last = lastEventAt, now - last > Self.gestureGap {
            travelled = 0
        }
        lastEventAt = now
        touchedAt = now
        travelled += abs(sample.deltaY)
        if sample.phase == .began || sample.phase == .changed { fingersDown = true }
        if sample.momentumPhase == .began || sample.momentumPhase == .changed { momentumLive = true }
        phaseless = sample.phase == .none && sample.momentumPhase == .none
        guard following else { return .kept }
        return travelled >= Self.stopDistance ? .stoppedFollowing : .nudged
    }

    /// What the stage should do about the page now.
    ///
    /// While a gesture is live nothing is due: the stage asks again shortly.
    /// Following, after a gesture too short to stop it: put the page back
    /// `gestureGap` after the last thing that happened to it — the lift or the
    /// glide's end as much as the last movement. Not following: follow again
    /// `resumeDelay` after that — but only while `pointerOverStage()` is false,
    /// and asked again every `pointerRecheck` seconds while it is true, so the
    /// page returns as soon as the pointer leaves. The pointer is a closure so
    /// it is asked only when the answer matters.
    func settle(following: Bool, pointerOverStage: () -> Bool, at now: TimeInterval) -> Settle {
        guard let touchedAt else { return .none }
        if isLive(at: now, pointerOverStage: pointerOverStage) { return .wait(Self.liveRecheck) }
        let due = touchedAt + (following ? Self.gestureGap : Self.resumeDelay)
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

import SwiftUI

enum Theme {
    // MARK: - The island's outline (spec §19.3)

    /// The island's outline springs on response 0.5, damping 0.75 for every
    /// change of its size: an activity growing out of the notch, one activity
    /// turning into another, opening into a surface, the body growing or
    /// folding, closing, and folding back into the notch.
    ///
    /// The one place Isla overshoots, about 3 % once, and a deliberate
    /// exception to the rule under it. That rule is about momentum — nothing a
    /// click opened should wobble at you — and it still holds for everything
    /// *inside* a surface. The outline is not something inside the interface:
    /// it is the object, a black shape growing out of the bezel, and the
    /// reference the owner chose on 2026-10-17 (spec §19, decision 15) draws
    /// it with exactly this overshoot. Drawn critically damped beside it, the
    /// same shape read as painted on rather than as a thing that arrived. 0.75
    /// keeps it to one swing: the return is under a tenth of a percent, so the
    /// eye sees the island arrive, not bounce.
    ///
    /// It is quicker off the mark than the 0.34 critically damped open it
    /// replaced — 99 % of the way in 0.28 s against 0.36 — crosses its end at
    /// 0.29 s, and is within half a point of it over the widest travel by
    /// 0.63 s. `MotionValuesTests` holds the values, the overshoot and every
    /// entry point that rides it; the content that arrives with it is
    /// `IslandArrival`.
    static let islandResponse: Double = 0.5
    static let islandDamping: Double = 0.75
    static let islandSpring = Animation.spring(response: islandResponse, dampingFraction: islandDamping)

    /// The outline under Reduce Motion: the 0.24 ease-in-out, no overshoot.
    static func island(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : islandSpring
    }

    /// The panel folding shut: the outline's own spring, started a beat late.
    ///
    /// The open's rule is that the panel has height before the body has alpha;
    /// the close has to be the same rule backwards, the body gone before the
    /// shape comes for it. It was not. Shape and body started in the same
    /// frame, the shape eats the 14 pt bottom padding in about 25 ms, and from
    /// there the clip was cutting through the rail and the time label while
    /// they were still 0.93 opaque (H-012; the visual lab's keyframes-close
    /// t033–t050). A close read as a blind dropping rather than as the open
    /// run backwards.
    ///
    /// Two halves fix it, and neither does alone. The body leaves on an
    /// ease-out (`paneOut`), which is fastest at the start rather than the
    /// end; and the shape waits 30 ms. Together the body is at about 0.26 when
    /// the clip first touches it. Keeping the ease-in and only delaying the
    /// shape leaves it at 0.88; dropping the delay and only flipping the curve
    /// still leaves it near 0.6. A slower spring would also do it and would
    /// lengthen every close, which is the one thing a close must not be.
    ///
    /// 30 ms is still immediate: the fade starts in the click's own frame and
    /// is the response, and the shape follows inside two frames. It does
    /// postpone the header strip and the cover's flight home by the same
    /// 30 ms, since they ride the shell's transaction.
    /// `PanelCloseTests.testTheBodyIsMostlyGoneBeforeTheClipReachesIt` holds
    /// the 0.30 ceiling from these constants, and
    /// `testTheHitAreaOutlastsTheDelayedClose` that the hit area still
    /// shrinks only after the later settle.
    static let closeShapeDelay: Double = 0.03
    static let closeAnimation = islandSpring.delay(closeShapeDelay)

    /// The outline opening (spec §19.3). Reduce Motion: the 0.24 crossfade.
    static func open(reduceMotion: Bool) -> Animation {
        island(reduceMotion: reduceMotion)
    }

    /// Reduce Motion gets the reduced open with no delay: the delay is
    /// choreography between two moving things, and that is what was refused.
    /// The lock path closes in a disabled transaction and never comes here.
    static func close(reduceMotion: Bool) -> Animation {
        reduceMotion ? open(reduceMotion: true) : closeAnimation
    }

    /// The pill growing out of the notch, and folding back into it, and its
    /// content arriving and leaving with it: the outline's spring, both ways
    /// (spec §19.3).
    ///
    /// The fold and the unfold were 0.42 critically damped springs, and the
    /// content rode a pair of its own — out at 0.20, in at 0.36 behind a 70 ms
    /// delay — so that it left before the contracting edge could slice through
    /// it and arrived after there was a wing under it (2026-09-21, H-013). The
    /// content has been pinned to the island's edges since the 2026-10-15
    /// redesign, so no edge crosses it any more, and the reference arrives its
    /// content on the shape's own curve: from blur and a narrower scale, with
    /// the shape, and leaves the same way reversed (`IslandArrival.compact`).
    /// One curve also ends the bare wing H-013 was about — the content is gone
    /// in the frame the shape is. `PillFoldTests` holds both.
    ///
    /// A lock-screen pause still folds as a motion and not a cut — the
    /// 2026-09-21 film — because the locked pill declares this curve beneath
    /// the lock's own refusal (`NotchContentView.lockedPill`).
    static func pill(reduceMotion: Bool) -> Animation {
        island(reduceMotion: reduceMotion)
    }

    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    /// The outgoing pane, and on a close the whole body.
    ///
    /// Out is an ease-out, not the ease-in it was. An ease-in starts at zero
    /// speed and ends at its fastest, so the leaving pane — and on a close,
    /// the whole body — stayed nearly opaque for its first frames and was then
    /// yanked away (H-028). The open's body arrives on an ease-out; the close
    /// now releases on one, at its fastest in the frame the click lands. 0.10
    /// rather than 0.12 because a curve that front-loads its change is
    /// perceived as done sooner: 90 % is gone by 75 ms, against 113 ms on the
    /// old curve, and it leaves at its peak speed instead of arriving at it.
    static let paneOutDuration: Double = 0.10
    static let paneOut = Animation.easeOut(duration: paneOutDuration)

    /// Every spring in this file that is **not** allowed to overshoot.
    ///
    /// Apple's own rule, from *Designing Fluid Interfaces*: start at a damping
    /// ratio of 1.0, and add overshoot **only when the gesture itself carried
    /// momentum** — a flick, a throw, a drag release. Bounce on something a
    /// flick threw feels right; bounce on something a click opened feels like
    /// the interface wobbling at you.
    ///
    /// Listed rather than inferred so the guard is a list somebody has to
    /// deliberately edit. It used to be hardcoded inside the test, which meant
    /// a fourth spring at 0.7 would have passed it without anyone noticing.
    ///
    /// The outline's curves left it on 2026-10-17 — the close, the pill's fold
    /// and unfold and its content, the pop-up's — because they are all
    /// `islandSpring` now (spec §19.3); what is left is every curve that moves
    /// something inside a surface.
    static let criticallyDampedSprings: [Animation] = [
        captionTurnOut, captionTurnIn, expandAnimation, lockCardMorph, hudSpring,
    ]

    /// The volume and brightness pop-up (redesign 2026-10-15, spec §2.4, §12)
    /// widens and folds on a spring of its own: response 0.3, critically
    /// damped, and its content arrives by opacity and a slight scale, with no
    /// blur (`hudArrival`).
    ///
    /// It rode the outline's 0.5 spring with its 0.75 damping from 2026-10-17,
    /// and its content focused in from a 30-point blur at 0.6 × 0.2 of its
    /// size. A key press is the most frequent thing the island answers and
    /// carries no momentum to express; on the owner's Mac (2026-10-18) the
    /// pop-up felt heavy and laggy beside the system's own, which appears at
    /// once and only fades, and the animated blur is among the costliest
    /// things SwiftUI draws, frame by frame on the main thread, while the Mac
    /// is busy (perf review, finding 3).
    static let hudResponse: Double = 0.3
    static let hudSpring = Animation.spring(response: hudResponse, dampingFraction: 1.0)

    /// The pop-up's curve, or the 0.24 ease-in-out under Reduce Motion.
    static func hud(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : hudSpring
    }

    /// The pop-up's content arriving and leaving on the shut island: opacity
    /// alone, over a tenth of a second. The geometry is the outline's — it grows
    /// out of the notch on `hudSpring` and clips the content as it goes — so the
    /// content has nothing to travel. It used to start at opacity 0 and 0.94 of
    /// its size on that same 0.3 s spring, which kept the symbol and the bar
    /// faint for the first 100 ms of a pop-up the person had asked for with a
    /// key press (owner, 2026-10-25: "no delaying"). Reduce Motion keeps the
    /// 0.24 s crossfade.
    static func hudArrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.animation(hudContentFade)
    }
    /// The capsule under the open panel arriving and leaving: it has no
    /// outline to grow out of, so its size rides `hudSpring` — 0.94 of itself
    /// about its top edge — while its opacity is up within a tenth of a second.
    static func hudStripArrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.animation(hudContentFade).combined(with: .scale(scale: hudArrivalScale, anchor: .top))
    }
    static let hudArrivalScale: CGFloat = 0.94
    static let hudContentFadeDuration: TimeInterval = 0.1
    static let hudContentFade = Animation.easeOut(duration: hudContentFadeDuration)

    /// The level bar has no curve. It was a critically damped spring of 0.2 s
    /// (spec §2.4, 2026-10-18), and a held key presses again every 30 to 35 ms,
    /// so the bar was always one to two steps behind the number beside it and
    /// the keys (owner, 2026-10-25: "it kind of lags … no freezing, no
    /// delaying"). The system's own bar is at the level the instant the key is,
    /// and a curve of any length, retargeted on every press, keeps SwiftUI
    /// laying the bar out on every frame of the hold: measured at about a
    /// quarter of the main thread's time in a held key (`hud-repeat`,
    /// `Scripts/measure-hitches.sh`). The bar steps, under Reduce Motion too.

    /// How long the pop-up stays after the *last* press (spec §2.4: 1.5 s idle)
    /// before it folds on the outline's spring. Each press
    /// restarts it.
    static let hudLinger: TimeInterval = 1.5

    /// The body growing from 208 to 400 and back (spec §2.4, §6): spring 0.40 /
    /// 1.0. A little slower than the open's 0.34 because it moves a body that is
    /// already on screen by 192 pt, with a cover, a title and a transport riding
    /// it — the longest travel the panel makes, and a travel the eye follows
    /// from a button at the top to a row at the bottom. Critically damped: a
    /// tall body that rebounded would show the tail of its own cut (the
    /// window is never resized, so the clip is the edge). `Lyrics-Frames` is the
    /// board.
    ///
    /// Since 2026-10-17 the island's body grows and folds on `islandSpring`
    /// (spec §19.3) — `island(reduceMotion:)` at every site that moves it — and
    /// this spring is left to the one block inside a surface that still grows:
    /// the Settings update card changing stage (`UpdateCard`).
    static let expandResponse: Double = 0.40
    static let expandAnimation = Animation.spring(response: expandResponse, dampingFraction: 1.0)

    /// When a shrinking body has, for a pointer, stopped: what may only shrink
    /// once the body has (the active and close rects,
    /// `NotchController.openRectHeight`) waits this long.
    ///
    /// The body shrinks on `islandSpring` now. It crosses its end at 0.29 s and
    /// overshoots *inward* — smaller than the body it is going to, so inside
    /// the rect cut for it — and the swing back out is under a tenth of a
    /// percent of the travel, 0.15 pt on the 192 pt fold. So from 0.29 s on no
    /// drawn point lies outside the smaller rect; 0.5 s, chosen for the
    /// critically damped 0.40 it replaced, still holds with room.
    /// `NotchControllerTests` checks it against the spring's closed form.
    static let expandSettle: TimeInterval = 0.5

    /// Reduce Motion: no travel, the 0.24 crossfade the rest of the panel uses.
    static func expand(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : expandAnimation
    }

    /// The lock banner growing into the card, and the card shrinking back
    /// (spec §2.4, §7.1): spring 0.36 / 1.0, **in place** — the banner's top edge
    /// is the card's top edge and both are centred on the same x, so the cover,
    /// the title and the artist travel down and out rather than being replaced.
    /// (`Lock-Frames` is the board: banner, halfway, card.) A touch slower than
    /// the panel's 0.34 open because the card is three times the banner's
    /// height and the eye follows the cover the whole way; critically damped,
    /// because the card's window is never resized and a rebound would show the
    /// tail of its own clip (see `LockCardWindow`).
    static let lockCardMorphResponse: Double = 0.36
    static let lockCardMorph = Animation.spring(response: lockCardMorphResponse, dampingFraction: 1.0)

    /// Reduce Motion: nothing travels, the 0.24 crossfade the rest of the app
    /// uses (`LockScreenCard` gives each form an identity of its own so the two
    /// shapes dissolve into one another).
    static func lockCardMorph(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : lockCardMorph
    }

    /// The Music pane's caption giving one lyric line up to the next
    /// (`AnyTransition.lyricLine`): the old line leaving and the new one
    /// arriving, each on a curve of its own.
    ///
    /// Both used to ride `lyricScroll`, the stage page's 0.42 s spring, so
    /// they crossed at the same instant: from 62 to 158 ms of every turn both
    /// lines were at least a quarter opaque under up to 3 pt of blur, and the
    /// visual lab's keyframes t083–t200 showed the two printed over each other
    /// (H-014). The one place lyrics are read without opening the stage
    /// stuttered on every line.
    ///
    /// The pill content's rule fixes it: out fast, in behind a short delay.
    /// The old line is under a quarter opaque by 78 ms and the new one passes
    /// a quarter at 85 ms, so they never share the slot legibly; by 120 ms the
    /// new line is at 0.52 and the old at 0.08. In is 0.29 rather than the
    /// round 0.30, which reached 0.499 at 120 ms and missed the half it was
    /// chosen for. `MotionValuesTests.testTheCaptionTurnNeverOverprints`
    /// holds all of it from the closed form of these three constants.
    ///
    /// Critically damped, unlike the page they used to share: a line that
    /// fades out of a one-line slot has no travel to overshoot that anyone
    /// could read as momentum, only a ghost that brightens again. And
    /// `lyricScroll` itself stays where it is — it still carries the stage's
    /// page, which must stay slower than the word sweep.
    static let captionTurnOutResponse: Double = 0.18
    static let captionTurnInResponse: Double = 0.29
    static let captionTurnInDelay: Double = 0.04
    static let captionTurnOut = Animation.spring(response: captionTurnOutResponse, dampingFraction: 1.0)
    static let captionTurnIn = Animation.spring(response: captionTurnInResponse, dampingFraction: 1.0)
        .delay(captionTurnInDelay)

    /// The lyrics page moving to the next line.
    ///
    /// The one animation here allowed to overshoot, and it is allowed because
    /// the rule at the top of this file is about momentum rather than about
    /// taste: the page is not something a click moved, it is carried by a voice
    /// that is already moving, and a page that stops dead the instant it
    /// arrives reads as the song being cut off rather than sung.
    ///
    /// It used to borrow `contentAnimation` — the generic 0.16s ease that also
    /// drives a badge appearing — for a page travel of one whole slot
    /// (`LyricsStage.slotHeight` 40 + `slotSpacing` 8 = 48pt). That put the page
    /// ahead of the word sweep it exists to carry: `KaraokeText` fills a line
    /// over `.linear(duration: 0.25)`, so the page had already settled at the
    /// reading centre while the sweep was barely half-way across the words it
    /// was moving them into view for. The page arrived before the voice did.
    /// The response therefore has to be longer than that 0.25s, not shorter.
    ///
    /// 0.86 is a small overshoot, deliberately — and smaller than it was once
    /// described: over the 48 pt step it computes to about 0.24 pt past the
    /// line (`exp(−ζπ/√(1−ζ²))` ≈ 0.5 % of the travel; the visual lab's
    /// `peakOvershootPoints` for `lyric-scroll` reads the same). That is under
    /// half a pixel on a Retina panel, so whatever makes the page read as
    /// carried, it is not a bump anybody sees. It is left at 0.86 on purpose
    /// until the owner has compared it live against 1.0 (Wave A decision 18);
    /// `LyricLeadModel` reads the rise from these two constants, so the line
    /// timing follows either answer. `MotionValuesTests`
    /// `testTheLyricScrollIsSlowerThanTheWordSweepAndMayOvershoot` holds both
    /// ends of the range, and `testNothingWithoutMomentumOvershoots` walks
    /// `criticallyDampedSprings` so this and `hoverNudge` stay the only
    /// exceptions (it used to say "the single exception"; the nudge was added
    /// after it). Any spring
    /// added to this file belongs in that list unless it can name the momentum
    /// it inherited.
    static let lyricScrollResponse: Double = 0.42
    static let lyricScrollDamping: Double = 0.86
    static let lyricScroll = Animation.spring(response: lyricScrollResponse,
                                              dampingFraction: lyricScrollDamping)

    /// Reduce Motion refuses the travel, and a spring is nothing but travel —
    /// so the page still moves to the next line, it just stops carrying
    /// anything there. Same `reducedMotion` every other variant here uses.
    static func lyricScroll(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : lyricScroll
    }

    /// How long a spring started at rest takes to cover `level` of its
    /// travel: SwiftUI's `spring(response:dampingFraction:)` as a damped
    /// oscillator with natural frequency 2π/response, read at its first
    /// crossing of `level`.
    ///
    /// The lyric lead needs it. `LyricRow` lights a line on `lyricScroll`,
    /// so the line the voice reaches is only half lit about 104 ms after the
    /// clock calls it — the largest render term the lyric lab found (L-09),
    /// and one no constant tracked: retune the spring and the line's
    /// perceived onset moves with it. `LyricLeadModel` reads the rise from
    /// here, from the same two constants the animation is built from, so the
    /// lead follows any change to them. The lab carried this as a private
    /// `SpringRise`; it lives here now so the app and the lab compute one
    /// number.
    ///
    /// Closed form per damping regime, scanned in 1 ms steps for the first
    /// crossing and then bisected: an underdamped spring passes `level`
    /// again on the way back from its overshoot, and only the first crossing
    /// is the one the eye sees.
    static func springRiseTime(response: Double, damping: Double, level: Double) -> TimeInterval {
        guard response > 0, damping > 0, level > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        func value(_ t: Double) -> Double {
            if damping < 1 {
                let damped = omega * (1 - damping * damping).squareRoot()
                return 1 - exp(-damping * omega * t)
                    * (cos(damped * t) + (damping * omega / damped) * sin(damped * t))
            }
            if damping == 1 { return 1 - exp(-omega * t) * (1 + omega * t) }
            let spread = omega * (damping * damping - 1).squareRoot()
            let fast = -damping * omega - spread, slow = -damping * omega + spread
            return 1 - (fast * exp(slow * t) - slow * exp(fast * t)) / (fast - slow)
        }
        let step = 0.001, limit = 10.0
        var high = step
        while value(high) < level {
            high += step
            if high > limit { return limit }
        }
        var low = high - step
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if value(mid) < level { low = mid } else { high = mid }
        }
        return high
    }

    /// The one swap of one song for the next, on every surface that draws a
    /// song: the closed island, the open player, the lyric stage and the lock
    /// card (`NowPlayingPresenter`, redesign spec §19.6 amendment 2026-10-25).
    ///
    /// Each surface used to animate whichever field it was handed, on its own
    /// curve — the player in two transactions, the island's cover keyed on the
    /// track and so crossfading the old picture into itself before cutting,
    /// the lock card not at all (owner, 2026-10-25); the 0.16 s
    /// `artworkAnimation` those used is withdrawn. One value now changes
    /// once, and this is how it changes: the cover crossfades from 0.96 of
    /// itself on a critically damped spring — nothing is thrown, so nothing
    /// overshoots — and the words crossfade in the same transaction. Apple
    /// Music's own skip is the reference: the picture settles, the type fades.
    static let trackSwapSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)

    /// The swap's curve: the spring, or under Reduce Motion the plain fade
    /// every other motion falls back to — a fade is not motion.
    static func trackSwap(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : trackSwapSpring
    }

    /// Where the cover's scale starts on a swap.
    static let trackSwapCoverScale: CGFloat = 0.96

    /// The incoming cover's transition: from 0.96 and transparent, opacity only
    /// under Reduce Motion. The outgoing one only fades, so the two are never
    /// two sizes at once.
    static func trackSwapCover(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: trackSwapCoverScale)),
                removal: .opacity
            )
    }

    /// Reduce Motion asks for the state change to still happen, just without
    /// the travel — so the spring becomes `reducedMotion`, which carries
    /// nothing past its end and starts and stops at rest, and scale
    /// transitions become plain opacity, rather than the panel snapping
    /// between states with no transition at all. (`open(reduceMotion:)`,
    /// `pill(reduceMotion:)` and `island(reduceMotion:)` are the outline's, at
    /// the top of this file.)
    ///
    /// The one curve for every travel Reduce Motion still has to make: the
    /// shell opening and closing, the pill and its content, the lyric page,
    /// the hover nudge.
    ///
    /// These were ease-outs of 0.12 and 0.15 s, on the reasoning that shorter
    /// is calmer. It is not. An ease-out leaves at its fastest, so the
    /// reduced open jumped 38.6 pt in its first frame and peaked at
    /// 2,518 pt/s, twice the 1,197 pt/s of the spring it stands in for (F-055,
    /// raised to P2 by Wave B): the people who asked for calm got the most
    /// abrupt path in the app, and a bezier that cannot merge on a reversal
    /// besides. An ease-in-out starts and ends at rest; at 0.24 s it moves
    /// 1.7 pt in the first frame and peaks at about 1,264 pt/s over the
    /// panel's 176 pt. A shorter ease-out was the other answer and makes the
    /// first-frame jump worse, not better. A true dissolve of the shell (two
    /// shape layers and a black slab fading in) was rejected for its cost.
    ///
    /// Opacity-only changes do not come here: a fade is not motion, and they
    /// keep `contentAnimation` with the setting on.
    /// `MotionValuesTests.testReduceMotionNeverJumpsTheFirstFrame` holds
    /// every variant to this one description and samples its first frame.
    static let reducedMotionDuration: TimeInterval = 0.24
    static let reducedMotion = Animation.easeInOut(duration: reducedMotionDuration)

    static func scaleIn(_ scale: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale))
    }

    /// The tab swap's scales: the arriving pane from 0.97, the leaving one
    /// to 0.98 (it grew to 1.02 until 2026-10-18, past the edges it was
    /// leaving), and 1 for both under Reduce Motion, so the swap is a plain
    /// crossfade. The swap built its scale inline beside `scaleIn`, which
    /// exists for exactly this, and so every tab switch still zoomed with the
    /// setting on (F-017).
    static func paneSwapScales(reduceMotion: Bool) -> (insertion: CGFloat, removal: CGFloat) {
        reduceMotion ? (1, 1) : (0.97, 0.98)
    }

    /// One surface replacing another in the open island — the gear opening
    /// Settings, its X closing it, the stage and the player trading places:
    /// the old pane leaves on `swapOut`, and the new one starts only once it
    /// has gone.
    ///
    /// The swap shared the open's `paneIn`/`paneOut`, whose 0.04 s delay lets
    /// the arriving body start while the leaving one is still most of the way
    /// opaque; the leaving pane also grew to 1.02 as it went. On the owner's
    /// film (2026-10-18) the gear's change from the player to Settings read
    /// as two screens printed over each other, inside an island that was
    /// growing at the same time: "make sure the motions are clean, not
    /// anything just overlapping". Now the leaving pane recedes to 0.98 and
    /// is gone in 0.08 s, the island growing on its spring meanwhile; the new
    /// one arrives from 0.97 about the top edge — hanging from the notch, as
    /// everything in the island does — beginning in the frame the old one
    /// ends. `MotionValuesTests.testASwapNeverShowsTwoPanesAtOnce` holds it.
    static let swapOutDuration: Double = 0.08
    static let swapOut = Animation.easeOut(duration: swapOutDuration)
    static let swapInDuration: Double = 0.20
    static let swapIn = Animation.easeOut(duration: swapInDuration).delay(swapOutDuration)

    /// The resting island's bottom corners, larger than the hardware notch's
    /// own so the curve stays inside the cutout rather than poking a black nub
    /// past it at each corner. Inside the cutout nothing is visible, which is
    /// the point: at rest the island *is* the notch. 12.67 since spec §19.2 —
    /// the reference's resting notch, and never less than the compact
    /// island's corner, so folding into the notch never gains one.
    static let restingNotchBottomRadius: CGFloat = 12.67

    /// The island waking under the pointer when it rests hidden in the notch.
    ///
    /// The one other animation here allowed to overshoot, and asked for by the
    /// owner on 2026-09-21: a hidden island has to say "I am here" the moment
    /// the pointer arrives, and a small bounce is what says it — the way the
    /// iPhone's island bumps when touched. It is deliberately *not* the
    /// `RefusalShake`: over the lock screen that shake already means "this will
    /// not open", and the same motion here would say "no" to a click that is
    /// about to work. 0.72 is a single bump that settles, not a wobble;
    /// `RestingNotchTests.testTheHoverNudgeIsOneBumpNotAWobble` holds that
    /// (this used to cite `MotionValuesTests`, which never asserted it).
    /// "Visible" is the open question: over the 15 pt each side travels it
    /// overshoots by about 0.58 pt (3.8 %), about one Retina pixel. The value
    /// stays until the owner, who asked for the bump, has looked at it live
    /// (Wave A decision 18) — a planner's arithmetic does not overrule that.
    static let hoverNudgeDamping: Double = 0.72
    static let hoverNudge = Animation.spring(response: 0.34, dampingFraction: hoverNudgeDamping)

    static func hoverNudge(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : hoverNudge
    }

    /// The compact island's shoulders and bottom corners, the reference's
    /// 8.67 and 12.67 (spec §19.2, §19.4; they were 6 and 12). Quadratic
    /// corners (`NotchShape`), so 12.67 reads lighter than a circular 12 did.
    /// Still no rounder than `restingNotchBottomRadius`, so the island folding
    /// into the notch never gains a corner.
    static let collapsedTopRadius: CGFloat = 8.67
    static let collapsedBottomRadius: CGFloat = 12.67
    // The open radii are the surface's own (`Surface.topRadius`,
    // `bottomRadius`, §19.2): 34 / 44, and 24 / 34 for the tray.
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    // A podcast is the case this exists for: without the roll, a two-hour
    // episode drew "120:45" into a gutter sized for "59:59" and came out as
    // "120:…". Under an hour the leading "0:" would be noise, so it is left off.
    guard hours > 0 else { return String(format: "%d:%02d", total / 60, total % 60) }
    return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
}

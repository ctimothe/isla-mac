import SwiftUI

enum Theme {
    /// Critically damped, on purpose.
    ///
    /// Apple's own rule, from *Designing Fluid Interfaces*: start at a damping
    /// ratio of 1.0, and add overshoot **only when the gesture itself carried
    /// momentum** — a flick, a throw, a drag release. Bounce on something a
    /// flick threw feels right; bounce on something a click opened feels like
    /// the interface wobbling at you.
    ///
    /// The island opens from a click. There is no momentum to inherit and there
    /// was nothing for the overshoot to express, so 0.82 spent it on a wobble
    /// at the end of every open. Response is the time to reach the target, not
    /// a duration — Apple ships 0.4 for a move and 0.3 for a sheet, and this
    /// sits between them.
    static let openResponse: Double = 0.34
    static let openAnimation = Animation.spring(response: openResponse, dampingFraction: 1.0)

    /// The panel folding shut: the open's own spring, started a beat late.
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
    static let closeAnimation = openAnimation.delay(closeShapeDelay)

    /// Reduce Motion gets the reduced open with no delay: the delay is
    /// choreography between two moving things, and that is what was refused.
    /// The lock path closes in a disabled transaction and never comes here.
    static func close(reduceMotion: Bool) -> Animation {
        reduceMotion ? open(reduceMotion: true) : closeAnimation
    }
    /// The pill resizing around a track that just started. Also nothing anybody
    /// threw, so also critically damped.
    static let compactAnimation = Animation.spring(response: 0.28, dampingFraction: 1.0)

    /// The pill growing out of the notch, and folding back into it.
    ///
    /// These used to be `compactAnimation` too, and on the lock screen they
    /// were not animations at all: a pause folded the pill away in a single
    /// frame, filmed on 2026-09-21 — "too intense, too raw". A fold is the
    /// island's largest idle motion, 52 pt of wing on each side going into a
    /// hole in the display, and at 0.28 s it read as a snap even where it did
    /// animate. Apple's own reposition is 0.4, and both sit just past it.
    ///
    /// The fold used to sit further out, at 0.5, on the argument that a fold
    /// nobody asked for should not pull the eye. It pulled it anyway, the
    /// wrong way: its content leaves on its own faster curve, so for about
    /// 300 ms after the cover was gone an empty black wing still hung past
    /// the notch (H-013, settled at 529 ms against the content's 233 ms).
    /// Leaving took longer than arriving. The fold now matches the unfold,
    /// which leaves about 230 ms of bare wing and keeps it above the 0.4
    /// floor that guards the 2026-09-21 "not a snap". Going further — the
    /// audit's 0.32 — lands within 0.04 s of the 0.28 that was the snap.
    /// `PillFoldTests` holds the order, the floor and the bare-wing time.
    /// Both critically damped — neither was thrown. The peek's end rides the
    /// fold too, so it got quicker by the same amount.
    static let pillUnfoldResponse: Double = 0.42
    static let pillFoldResponse: Double = 0.42
    static let pillUnfold = Animation.spring(response: pillUnfoldResponse, dampingFraction: 1.0)
    static let pillFold = Animation.spring(response: pillFoldResponse, dampingFraction: 1.0)

    /// The fold or the unfold, by where the pill is going.
    static func pill(appearing: Bool, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reducedMotion }
        return appearing ? pillUnfold : pillFold
    }

    /// The pill's own content — the cover and the equalizer — arriving and
    /// leaving, on a curve of its own rather than the shape's.
    ///
    /// Out faster than the wing it sits on: the content has to be gone before
    /// the contracting edge reaches it, or the edge slices through the cover
    /// on its way into the notch. In behind a short delay, so there is a wing
    /// under it before it materializes — content drawn ahead of its surface is
    /// content floating on the wallpaper. `PillFoldTests` holds both halves
    /// against the shape's own springs.
    ///
    /// Out is tied to the fold: when the fold quickened to 0.42 its edge
    /// reached the 22 pt cover sooner (130 ms instead of 154), and at the old
    /// 0.22 the cover was still 12 % opaque there. 0.20 is the largest
    /// hundredth that keeps it under a tenth (about 0.09) when the edge
    /// arrives; 0.21 misses by a hair. Any slower and the edge slices the
    /// cover, any faster and the cover blinks out rather than leaves.
    static let pillContentOutResponse: Double = 0.20
    static let pillContentInResponse: Double = 0.36
    static let pillContentInDelay: Double = 0.07
    static let pillContentOut = Animation.spring(response: pillContentOutResponse, dampingFraction: 1.0)
    static let pillContentIn = Animation.spring(response: pillContentInResponse, dampingFraction: 1.0)
        .delay(pillContentInDelay)

    static func pillContent(shown: Bool, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reducedMotion }
        return shown ? pillContentIn : pillContentOut
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
    /// Listed rather than inferred so the guard is a list somebody has to
    /// deliberately edit. It used to be hardcoded inside the test, which meant
    /// a fourth spring at 0.7 would have passed it without anyone noticing.
    static let criticallyDampedSprings: [Animation] = [
        openAnimation, closeAnimation, compactAnimation, pillUnfold, pillFold, pillContentOut, pillContentIn,
        captionTurnOut, captionTurnIn, expandAnimation, lockCardMorph,
    ]

    /// The body growing from 208 to 400 and back (spec §2.4, §6): spring 0.40 /
    /// 1.0. A little slower than the open's 0.34 because it moves a body that is
    /// already on screen by 192 pt, with a cover, a title and a transport riding
    /// it — the longest travel the panel makes, and a travel the eye follows
    /// from a button at the top to a row at the bottom. Critically damped: a
    /// tall body that rebounded would show the tail of its own cut (the
    /// window is never resized, so the clip is the edge). `Lyrics-Frames` is the
    /// board.
    static let expandResponse: Double = 0.40
    static let expandAnimation = Animation.spring(response: expandResponse, dampingFraction: 1.0)

    /// When the expand spring has, for a pointer, stopped: a critically damped
    /// spring of response 0.40 is within a pixel of its end a little after
    /// 0.45 s. What may only shrink once the body has stopped (the active and
    /// close rects, `NotchController.openRectHeight`) waits this long.
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

    // A skip delivers its new title and cover in 68ms, so the crossfade is
    // what the wait actually is. Short enough to read as immediate, long
    // enough that the swap is still a fade rather than a cut.
    static let artworkAnimation = Animation.easeOut(duration: 0.16)

    /// Motion-aware variants. Reduce Motion asks for the state change to
    /// still happen, just without the travel — so the spring becomes
    /// `reducedMotion`, which carries nothing past its end and starts and
    /// stops at rest, and scale transitions become plain opacity, rather
    /// than the panel snapping between states with no transition at all.
    static func open(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : openAnimation
    }

    static func compact(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : compactAnimation
    }

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
    /// to 1.02, and 1 for both under Reduce Motion, so the swap is a plain
    /// crossfade. The swap built its scale inline beside `scaleIn`, which
    /// exists for exactly this, and so every tab switch still zoomed with the
    /// setting on (F-017).
    static func paneSwapScales(reduceMotion: Bool) -> (insertion: CGFloat, removal: CGFloat) {
        reduceMotion ? (1, 1) : (0.97, 1.02)
    }

    // MARK: - Type

    /// Letter-spacing for a given size, following the shape of SF's own
    /// tracking table.
    ///
    /// Tracking is size-specific and a single value is wrong somewhere: as type
    /// grows, the same spacing reads as letters drifting apart, so large text
    /// wants *negative* tracking; small text wants slightly positive to stay
    /// legible. Apple ships a table for this and applies it automatically to the
    /// semantic text styles — `.headline`, `.body` — but **not** to
    /// `.system(size:)`, which is what a fixed-size panel has to use. So it is
    /// applied here by hand.
    ///
    /// Why not the semantic styles: they scale with the user's text size, and
    /// both surfaces this app draws are windows that cannot resize. The lock
    /// card is a fixed 460×300 whose window is deliberately never resized, and
    /// larger type would simply be cut off. Honest tracking on a fixed size is
    /// worth more than a Dynamic Type that overflows.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        switch size {
        case ..<12: return 0.07      // small labels open up a little
        case ..<15: return 0         // body sits at the neutral point
        case ..<18: return -0.2
        case ..<23: return -0.35
        default: return -0.5         // display sizes tighten most
        }
    }

    /// Six roles, not fifteen sizes.
    ///
    /// Every size here was chosen locally and well, which is how there came to
    /// be fifteen of them — 7, 8, 9, 10, 10.5, 11, 11.5, 12, 13, 15, 16, 20,
    /// 21, 22, 26, 28, plus computed. A reader cannot tell 10pt from 11pt
    /// apart as a decision, only as noise, so the roles are the vocabulary and
    /// a size that is not a role has to justify itself where it stands. Each
    /// role sits at the rung its cluster already gathered around: the 9pt
    /// labels carrying most of the panel rise to the caption floor AppKit
    /// itself sets at 10pt, the 10.5/11.5 in-betweens rejoin the body they
    /// were always a rounding away from, and the lyric stage's 15 meets the
    /// card's 16 at the title they already shared a tracking band at.
    ///
    /// `tracking(forSize:)` stays: the table is Apple's, indexed by points,
    /// and the roles read from it rather than replacing it.
    enum TypeRole: CaseIterable {
        /// Tab titles, counters, scrubber times, section headers, footnotes —
        /// most of the panel's labels. AppKit's own caption floor.
        case caption
        /// The reading voice: row titles, translated text, status lines.
        case body
        /// The redesign's reading text (spec §2.2): the boards' 12 and 12.5 —
        /// a player's subtitle, a clipboard row, the charge level and a device
        /// name on the compact island. Half a point over `body`, which is the
        /// difference between a status line and a line that is the content.
        case reading
        /// One step up from reading: rail icons, empty-state status, picker rows.
        case subhead
        /// Track titles and lyric lines.
        case title
        /// The tall lyric page (spec §2.2): 17 pt, a step over `title` because
        /// the page is read from an arm's length and the sung line is carried
        /// by weight and brightness, never by size (decision 6).
        case lyric
        /// Empty-state glyphs and transport symbols.
        case display
        /// The artwork placeholder and the lock card's play button.
        case hero

        var size: CGFloat {
            switch self {
            case .caption: return 10
            case .body: return 11
            case .reading: return 12.5
            case .subhead: return 13
            case .title: return 16
            case .lyric: return 17
            case .display: return 21
            case .hero: return 28
            }
        }

        /// What the role usually weighs. Titles arrive semibold; everything
        /// else arrives medium and says so only when it wants otherwise.
        var weight: Font.Weight {
            switch self {
            case .title: return .semibold
            default: return .medium
            }
        }

        /// The role as a `Font`, for the places a view modifier cannot reach —
        /// a `KaraokeText` parameter, a monospaced digit chain, a button style.
        func font(weight: Font.Weight? = nil) -> Font {
            .system(size: size, weight: weight ?? self.weight)
        }
    }

    /// The resting island's bottom corners, larger than the hardware notch's
    /// own so the curve stays inside the cutout rather than poking a black nub
    /// past it at each corner. Inside the cutout nothing is visible, which is
    /// the point: at rest the island *is* the notch.
    static let restingNotchBottomRadius: CGFloat = 12

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

    static let collapsedTopRadius: CGFloat = 6
    /// 12 since 2026-10-15 (spec §2.3; it was 9): the 24 pt cover's 6 pt corner
    /// sits 8 pt in, and a bottom corner of 12 is what keeps the two
    /// concentric. Still no rounder than `restingNotchBottomRadius`, so the
    /// island folding into the notch never gains a corner.
    static let collapsedBottomRadius: CGFloat = 12
    /// The peek island's bottom corners (spec §2.3): 16, concentric with the
    /// 34 pt cover's 8 pt corner inset 8.
    static let peekBottomRadius: CGFloat = 16
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22
    /// The tall body's bottom corners (spec §2.3): 26 against the standard
    /// body's 22, so the corner stays in proportion with the height it closes
    /// and the radius springs 22 → 26 with the body (`NotchShape` animates it).
    static let tallBottomRadius: CGFloat = 26

    static func openBottomRadius(tall: Bool) -> CGFloat {
        tall ? tallBottomRadius : openBottomRadius
    }

    // MARK: - Lyric column and tall page (spec §5.4)

    /// The Sync pill's solid fill: `#3A3A3C` at 0.96. A solid, not glass — it
    /// sits in an opaque panel with nothing behind it to sample — and a Theme
    /// value rather than a colour written at the view, as the rule asks.
    static let syncPillFill = Color(red: 58.0 / 255, green: 58.0 / 255, blue: 60.0 / 255).opacity(0.96)
    static let syncPillSize = CGSize(width: 74, height: 24)

    /// The version-mismatch notice: 488 x 40, radius 9, white 0.07 with a
    /// hairline (`Lyrics-Version-Mismatch`). Its width is the pane's at the
    /// default body; it follows the pane at other widths.
    static let mismatchNoticeHeight: CGFloat = 40
    static let mismatchNoticeRadius: CGFloat = 9
    static let mismatchNoticeFill = Color.white.opacity(0.07)

    /// The Edit Lyrics sheet (spec §5.5, `Lyrics-Editor`): `#2A2A2C`, with fields
    /// at white 0.06 inside a white 0.16 hairline.
    static let sheetFill = Color(red: 42.0 / 255, green: 42.0 / 255, blue: 44.0 / 255)
    static let editorFieldFill = Color.white.opacity(0.06)
    static let editorFieldEdge = Color.white.opacity(0.16)

    /// The instrumental gap's three dots (spec §5.4): 7 pt, white at 0.9, 0.55
    /// and 0.3 — a rest in the song, not a loading indicator, so they do not
    /// move.
    static let instrumentalDotSize: CGFloat = 7
    static let instrumentalDotSpacing: CGFloat = 6
    static let instrumentalDotOpacities: [Double] = [0.9, 0.55, 0.3]

    // MARK: - Artwork

    /// The two ends of the cover's travel between the pill and the open panel.
    ///
    /// One function because there is one cover. The pill hardcoded 22 pt at
    /// radius 6 in `NotchContentView` and the pane hardcoded 118 pt at radius 14
    /// in `MediaPane` — two descriptions of one object, in two files, which is
    /// the same mistake as drawing it twice and crossfading between the copies.
    /// A `matchedGeometryEffect` interpolates the frame; what it cannot do is
    /// notice that the two ends disagree about what shape they are.
    ///
    /// The corner is absolute at each end, not a proportion of the side.
    ///
    /// It was briefly proportional, at the `side / 5.5` `LockScreenCard` draws
    /// its own cover at, on the reasoning that one object should keep its shape
    /// while it travels. That is the wrong reasoning and it shows: a thumbnail
    /// wants to read as a rounded chip and a large cover wants to read as a
    /// picture, which is why Apple's small artwork is proportionally rounder
    /// than its large artwork rather than the same. Holding the ratio put the
    /// 118 pt cover at 21.5 pt — 18 per cent — a chip the size of a postcard.
    /// `side / 5.5` is right for the 42–62 pt thumbnail it was set on and wrong
    /// at this size, so each end keeps the value it actually wants and the
    /// morph interpolates the frame between them.
    ///
    /// The compact end is 24 pt at radius 6 since 2026-10-15 (spec §3.1; it was
    /// 22): the wing is 40 pt wide with the cover 8 pt in from the island's
    /// edge, and the 6 pt corner is concentric with the island's 12.
    ///
    /// The open end is 132 pt since 2026-10-15 (spec §4.1; it was 118): the
    /// board's player is a 132 pt cover at (58, 54) with the text column to its
    /// right. The radius stays 14, which is still a picture and not a chip
    /// (`ArtworkMorphTests`).
    static func artworkMetrics(isOpen: Bool) -> (side: CGFloat, cornerRadius: CGFloat) {
        isOpen ? (132, 14) : (24, 6)
    }

    /// The cover while a new track peeks (spec §3.5): 34 pt at radius 8,
    /// concentric with the peek's 16 pt corner and 8 pt inset. A third size of
    /// the one cover, not a second cover — the pill's artwork view takes it
    /// while `isPeeking` and the frame interpolates between the two.
    static let peekArtworkMetrics: (side: CGFloat, cornerRadius: CGFloat) = (34, 8)

    // MARK: - The compact island's surface (spec §2.1, §3.2, §3.3)

    /// A paused cover darkens to 0.55 of itself rather than turning 0.58
    /// see-through (spec §3.2). The old opacity let a bright wallpaper
    /// through the cover — on a pale desktop a paused cover read as a ghost —
    /// where multiplying the picture by 0.55 darkens it on any background.
    static let pausedCoverBrightness: Double = 0.55

    /// The well behind a missing cover on the compact island (spec §3.2): white
    /// at 0.14 under a `music.note`, drawn in place of the picture so the left
    /// wing never reads as a hole.
    static let coverWell = Color.white.opacity(0.14)

    // MARK: - The player (spec §4)

    /// The owner's red, `#FF453A` (spec §2.1): the LIVE mark and the circle under
    /// the output that is playing. Fixed rather than the system accent — it is
    /// a mark of Isla's own — and white on it holds the 3:1 non-text floor
    /// (3.4:1), which is all a glyph in a circle is asked for.
    static let accent = Color(red: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255)
    static let accentNSColor = NSColor(srgbRed: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255, alpha: 1)

    /// A paused cover in the player dims to 0.8 of itself (spec §4.2) — the
    /// island's 0.55 is for a 24 pt thumbnail that has to read as asleep; a 132
    /// pt picture only needs to say so. Applied with `colorMultiply`, never
    /// SwiftUI's `.brightness`, which is additive and would lift the black.
    static let playerPausedCoverBrightness: Double = 0.8

    /// The sung line while paused (spec §4.2): 0.7 of itself.
    static let playerPausedLyricOpacity: Double = 0.7

    /// The lyric band's *next* line (spec §4.3): the board's white 0.36 is the
    /// panel's own lyric floor (`LyricRow.Ramp.panel(...).floor`, held at 3:1 over
    /// black by `ContrastRampTests`), so the band follows the ramp instead of
    /// stating a second 0.36 that could drift from it — and Increase Contrast
    /// lifts it with the rest of the ramp.
    static func lyricBandNextOpacity(increaseContrast: Bool) -> Double {
        LyricRow.Ramp.panel(increaseContrast: increaseContrast).floor
    }

    @MainActor static var lyricBandNext: Color {
        Color.white.opacity(lyricBandNextOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// White 0.30 (0.50 with Increase Contrast): placeholders and glyphs nobody
    /// has to read (spec §2.1 `quaternary`) — the note in a missing cover's well.
    static func quaternaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.50 : 0.30
    }

    @MainActor static var quaternary: Color {
        Color.white.opacity(quaternaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// The well that stands in for a missing cover (spec §4.7): white 0.08, the
    /// board's `fill` token.
    static let coverMissingWell = Color.white.opacity(0.08)

    /// The empty player's well, edge and note (spec §4.8): a step under the
    /// missing cover's, so a player with nothing in it reads as emptier than one
    /// whose song has no picture.
    static let emptyWell = Color.white.opacity(0.07)
    static let emptyWellEdge = Color.white.opacity(0.10)
    static let emptyWellNote = Color.white.opacity(0.26)

    /// The note in a missing cover's well, and in the empty player's: 35 and 40
    /// points (spec §4.7, §4.8). Glyphs fitted to a 132 pt well, not type, so
    /// they are sizes of their own and not roles.
    static let playerCoverNoteSize: CGFloat = 35
    static let emptyNoteSize: CGFloat = 40

    /// The glyphs of the player's transport (spec §4.1): previous and next 16 pt,
    /// play and pause 20 pt, each in a 28 pt target.
    static let playerSkipGlyphSize: CGFloat = 16
    static let playerPlayGlyphSize: CGFloat = 20
    static let playerTransportTarget: CGFloat = 28

    /// The mark on a hairline round the player's cover (spec §4.1): white 0.14.
    static let coverEdge = Color.white.opacity(0.14)

    /// The island's colour under the pointer: a solid `#1C1C1E` in place of the
    /// white gradient lift it wore until 2026-10-15. Nothing moves on a playing
    /// island — the surface alone answers the pointer — and the resting notch's
    /// nudge (`hoverNudge`) grows into the same fill.
    static let islandHover = Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)

    /// The system green, `#30D158`: the charging bolt and its level.
    static let chargingGreen = Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

    /// The key line's strengths (spec §3.1 board, §3.3): the cover's tint at
    /// half strength round a music island or panel, white at 0.26 round every
    /// other. To be confirmed on hardware, owed check R1-H2.
    static let keyLineMusicOpacity: Double = 0.50
    static let keyLineNeutralOpacity: Double = 0.26
    static let keyLineWidth: CGFloat = 1

    // MARK: - Contrast ramp
    //
    // Every token below is a function of Increase Contrast, not a flat value.
    // The setting used to reach two `strokeBorder` calls in `GlassSurface` and
    // nothing else, while the type ramp sat untouched and the lyric context
    // lines at white 0.18 computed to 1.54:1. The opacity functions are pure so
    // tests can compute WCAG ratios against black (`ContrastRampTests`); the
    // `Color` accessors below read `SystemAppearance.shared.increaseContrast`,
    // and the one observation that makes a live change redraw lives on
    // `NotchContentView` — every pane is its descendant, so one `@ObservedObject`
    // at the root invalidates the whole tree.
    //
    // The existing names keep working so call sites do not all change at once;
    // new code that cares about the setting can call the functions directly.

    /// White 0.55 over black is 6.27:1; 0.75 is 11.45:1.
    static func secondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.75 : 0.55
    }

    /// Carries nearly every 9–10pt label in the panel — tab titles, counters,
    /// scrubber times, section headers, placeholders. At 0.32 white over black
    /// that computes to 2.67:1, far under the 4.5:1 WCAG AA asks of text this
    /// size, and 9pt is precisely the type least able to afford it. 0.46 gave
    /// 4.58:1 over black and cleared it there, but a label seldom sits on bare
    /// black: on `surface` (Settings notes, section rows) it was 4.29:1
    /// (F-052). 0.50 is 5.28:1 over black and 4.8:1 on `surface`, without
    /// turning every label into a headline; 0.65 gives 8.60:1 once Increase
    /// Contrast is on. The fills that are brighter still — a hovered Shelf
    /// card, the stacked capsules of a choice row — raise the label per
    /// fill with `tertiaryOpacity(over:increaseContrast:)`.
    static func tertiaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.65 : 0.50
    }

    /// The panel's translucent white fills a label can sit on, by name, so a
    /// label's backdrop is stated once and measured by `ContrastRampTests`.
    enum Fill {
        case surface, surfaceHover, selectedChip

        func opacity(increaseContrast: Bool) -> Double {
            switch self {
            case .surface: return Theme.surfaceOpacity(increaseContrast: increaseContrast)
            case .surfaceHover: return Theme.surfaceHoverOpacity(increaseContrast: increaseContrast)
            case .selectedChip: return Theme.selectedChipOpacity(increaseContrast: increaseContrast)
            }
        }
    }

    /// What an unselected option of a Settings choice row sits on: the section
    /// card's `surface` and the capsule group's own `surface` on top of it. At
    /// Increase Contrast those two stack to 0.48 of white, where even pure white
    /// text reaches only 4.24:1, so the capsule group gives up its fill for the
    /// defined edge that setting asks for and the option sits on the card alone.
    static func choiceOptionFills(increaseContrast: Bool) -> [Fill] {
        increaseContrast ? [.surface] : [.surface, .surface]
    }

    /// The grey (sRGB, 0…1) that white layers of these opacities make over the
    /// panel's black, source-over, first layer first.
    static func composite(_ opacities: [Double]) -> Double {
        opacities.reduce(0) { grey, alpha in alpha + (1 - alpha) * grey }
    }

    /// WCAG contrast of white at `textOpacity` over an sRGB grey.
    static func contrast(textOpacity: Double, overGrey grey: Double) -> Double {
        LockCardLegibility.contrast(textOpacity: textOpacity, overGrey: grey)
    }

    /// The smallest white opacity, no dimmer than the tertiary ramp, that
    /// clears 4.5:1 over these stacked fills. Searched in whole percent so the
    /// answer is a value a designer would write; the tertiary ramp itself is
    /// returned where it already clears.
    static func tertiaryOpacity(over fills: [Fill], increaseContrast: Bool) -> Double {
        let base = tertiaryOpacity(increaseContrast: increaseContrast)
        let grey = composite(fills.map { $0.opacity(increaseContrast: increaseContrast) })
        var candidate = base
        while candidate < 1, contrast(textOpacity: candidate, overGrey: grey) < 4.5 {
            candidate = (candidate * 100).rounded() / 100 + 0.01
        }
        return min(candidate, 1)
    }

    /// `tertiaryOpacity(over:increaseContrast:)` as a colour, at the live
    /// Increase Contrast setting.
    @MainActor static func tertiary(over fills: [Fill]) -> Color {
        Color.white.opacity(tertiaryOpacity(over: fills, increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// A filled shape has to read as a filled shape. 0.08 was 1.14:1 over
    /// black — the selected tab chip and the empty scrubber track were not
    /// visible as shapes at all. 0.16 is 1.44:1, the smallest round value that
    /// clears the 1.4 floor `ContrastRampTests` holds; this is a shape fix for
    /// everyone, not an accessibility variant, so the base moves and not only
    /// the contrast one.
    static func surfaceOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.28 : 0.16
    }

    /// 0.14 was 1.35:1. 0.26 is 2.10:1, the smallest round value clearing the
    /// 2.0 floor — same reasoning as `surfaceOpacity`: the hover state has to
    /// differ from the surface by something a person can see.
    static func surfaceHoverOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.38 : 0.26
    }

    /// A 1pt edge, not a fill, so the base stays hairline-thin at 0.10
    /// (1.20:1) and only the contrast variant becomes a defined border at
    /// 0.55 — the same white-0.55 `ShelfPane`'s selected tile already uses.
    /// Hairline-only edges stay thin by design; raising them is follow-up, not this change.
    static func hairlineOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.55 : 0.10
    }

    /// The selected rail chip's own fill, following `ShelfPane`'s selected
    /// tile: a 0.18 fill plus a 1.5pt white-0.55 border. It used to borrow
    /// `surfaceHover`, which meant the selected tab and a hovered tab were the
    /// same colour and neither had an edge.
    static func selectedChipOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.30 : 0.18
    }

    /// The selected chip's edge: `ShelfPane`'s 0.55, or the 0.85 defined
    /// border `GlassSurface` draws under Increase Contrast.
    static func selectedChipBorderOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.85 : 0.55
    }

    @MainActor static var secondary: Color {
        Color.white.opacity(secondaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var tertiary: Color {
        Color.white.opacity(tertiaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surface: Color {
        Color.white.opacity(surfaceOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surfaceHover: Color {
        Color.white.opacity(surfaceHoverOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var hairline: Color {
        Color.white.opacity(hairlineOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var selectedChip: Color {
        Color.white.opacity(selectedChipOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var selectedChipBorder: Color {
        Color.white.opacity(selectedChipBorderOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    // MARK: - The Settings switch
    //
    // AppKit's switch draws its on-state only in a key window, and this panel
    // is never key outside Translate, so every switch in Settings drew in the
    // inactive style: on and off differed by which side the knob sat on and a
    // track a shade lighter (H-002, four personas, the privacy rows worst of
    // all). `PanelSwitchStyle` draws its own, from these.

    /// On is the person's own accent, the colour every switch on their Mac is
    /// on in. `controlAccentColor` resolves at draw time and does not ask
    /// whether the window is key, which is the whole point.
    static let switchOnFill = Color(nsColor: .controlAccentColor)

    /// Off is a well shaded into the card, not a lighter fill on top of it.
    ///
    /// The plan said `surfaceHover`, and the arithmetic said no: a white fill
    /// on a white-0.16 card brightens the very thing the accent has to stand
    /// out from, and graphite on that measured 1.86:1 and blue 1.55:1 —
    /// on and off told apart by the knob again. Shading the card by 0.30
    /// leaves every accent macOS offers at 3.47:1 or more (purple is the
    /// lowest, graphite 5.04), and 0.50 holds it at 3.19 once Increase
    /// Contrast has brightened the card itself. `ContrastRampTests` measures
    /// all eight against the card. The well is still a shape — the hairline
    /// draws its edge — the way AppKit's own off track is a recess.
    static func switchWellOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.50 : 0.30
    }

    @MainActor static var switchOffFill: Color {
        Color.black.opacity(switchWellOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// The knob, white in both states as AppKit's is, with the faint shadow
    /// that keeps it a disc on the yellow accent, where white on yellow is
    /// barely an edge.
    static let switchKnob = Color.white
    static let switchKnobShadow = Color.black.opacity(0.3)

    /// Increase Contrast's defined border, on and off alike: the system draws
    /// one round its own controls with the setting on, and a switch that
    /// relies on fill alone is exactly what the setting is for.
    static let switchContrastOutline = Color.white.opacity(0.7)

    /// A little bigger than the 24×14 mini switch it replaces, so the state is
    /// worth seeing from across a call, and still well inside the 26 pt row.
    /// The size is no longer the target — the row is — so it can be sized for
    /// the eye alone.
    static let switchTrackSize = CGSize(width: 30, height: 17)
    static let switchKnobDiameter: CGFloat = 13

    // MARK: - The lock card's own ramp
    //
    // The card is not the panel and does not share its numbers. The panel is
    // white on its own black, where 0.46 is a readable label; the card floats
    // over whatever wallpaper is behind the shield, so its type runs brighter
    // to survive a pale one. That much was always deliberate.
    //
    // What was not deliberate is that the card carried those numbers as
    // literals — twenty-two of them — so Increase Contrast reached every label
    // in the panel and nothing at all here, on the one surface a person reads
    // from across a room. These are the same three roles the panel has, at the
    // card's own values, as functions of the setting like everything else.
    //
    // Where a literal fell between two roles it was rounded *up*, never down:
    // nothing on the card is dimmer than it was.

    /// Titles and the labels beside them. Was 0.55–0.62 in four places.
    ///
    /// 0.62 became 0.75 with F-003: over a pale cover the artist line was
    /// 1.76:1. The wash `LockCardLegibility` solves does most of that work; a
    /// brighter token is what lets it do it without darkening the cover as far.
    static func cardSecondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.85 : 0.75
    }

    /// Supporting text: the lyric status, the picker's rows, the volume
    /// glyphs. Was 0.40–0.50 in five places, and 0.40 over a bright wallpaper
    /// is barely there.
    ///
    /// 0.50 became 0.62 with F-003, for the same reason as `cardSecondary`:
    /// this is the token the cover's wash is solved against, so every point it
    /// gains is light a pale cover keeps.
    static func cardTertiaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.75 : 0.62
    }

    /// A filled shape that has to read as one: the artwork well, the unselected
    /// output dot. 0.08 was 1.14:1 over black — the same invisible-shape bug
    /// the panel's `surface` had, still sitting here.
    static func cardFillOpacity(increaseContrast: Bool) -> Double {
        // 0.16 rather than a tidier 0.14 for the same reason `surfaceOpacity`
        // is 0.16: it is the smallest round value clearing the 1.4 floor that
        // `ContrastRampTests` holds. 0.14 computes to 1.35:1 and is a shape
        // you cannot quite see.
        increaseContrast ? 0.28 : 0.16
    }

    /// The empty half of a bar — the seek track, the volume track.
    static func cardTrackOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.36 : 0.22
    }

    /// A 1pt edge on the card, not a fill.
    static func cardHairlineOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.55 : 0.25
    }

    @MainActor static var cardSecondary: Color {
        .white.opacity(cardSecondaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardTertiary: Color {
        .white.opacity(cardTertiaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardFill: Color {
        .white.opacity(cardFillOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardTrack: Color {
        .white.opacity(cardTrackOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var cardHairline: Color {
        .white.opacity(cardHairlineOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }

    /// Only for an action that destroys something, and only once it is armed.
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.40)
    /// A copy that landed, a tick that means done. The system green, named so
    /// the two places that flash it cannot drift to two greens.
    static let success = Color.green

    /// Tracking for an uppercased caption — the tab title, a section header, a
    /// column title. Capitals set at caption size close up, so they take a
    /// little more air than the table gives lowercase at that size. One value:
    /// the three headers used to carry 0.8, 0.8 and 0.6 for the same role.
    static let capsTracking: CGFloat = 0.8

    /// A Shelf card whose disk is not plugged in draws its preview at this
    /// opacity: present enough to be recognised as the same card, faded
    /// enough to read as out of reach before its caption is read. The
    /// caption itself stays at the tertiary ramp, which is what carries the
    /// words.
    static let offlineThumbnailOpacity: Double = 0.45

    /// The smallest target a caption-sized control in the panel may offer.
    /// A word set at the caption role is 13 pt tall, and a button that is
    /// only its word left Shelf's Deselect a 44x13 sliver beside the
    /// destructive Clear (F-014). The width still follows the word; this is
    /// the floor under both.
    static let minimumHitSize = CGSize(width: 24, height: 20)

    /// A Shelf card under a held mouse button settles to this scale, so the
    /// press answers on the way down rather than on release (F-038): a card
    /// took the mouse-down with no sign of it until a drag image appeared or
    /// the click was let go. Small, because a card is a large target and a
    /// deeper dip reads as a button.
    static let pressScale: CGFloat = 0.97
    /// The same press under Reduce Motion, which asks for no change of size:
    /// the card dims to this opacity instead.
    static let pressDimOpacity: Double = 0.85

    /// How far a list fades into an edge that cuts it (`scrollEdgeFade`,
    /// H-017). Ten points: enough to read as "continues" at a 26 pt row, and
    /// short enough that a covered clipboard row under the drifting dots
    /// still reads as covered rather than as a third state.
    static let scrollFadeLength: CGFloat = 10
}

/// The pressed state `.plain` does not give.
///
/// Apple's rule is feedback on press-down, not on release: a control that
/// shows nothing until the click is let go feels dead for the length of the
/// press. `.buttonStyle(PanelButtonStyle())` on macOS leaves a custom label untouched while
/// it is held, so every plain button in the panel — rows, chips, glyphs, the
/// rail — went through the press with no answer. This dims the label the same
/// way `NotchButtonStyle` and `TransportGlyphStyle` already do, so one press
/// looks like one press everywhere.
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// The panel's one-action pill: a word in a capsule of `Theme.surface` edged
/// with the hairline, dimmed on press the way `PanelButtonStyle` dims.
///
/// It was hand-copied three times — Music's "Open Spotify", the lyrics page's
/// "Look Up Online", the welcome page's "Get Started" — while Translate's
/// remedies, the only way forward from the first error a newcomer meets, were
/// bare bold caption text that did not look clickable at all (H-007). One
/// style now, so an offer looks like an offer wherever it appears.
///
/// The parameters exist so the copies could move onto it without a pixel
/// changing: Music's empty state is 2 pt narrower on each side, and the
/// welcome page's primary sits one step brighter on `Theme.surfaceHover`.
/// A new offer takes the defaults.
struct OfferButtonStyle: ButtonStyle {
    var fill: Color = Theme.surface
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 5
    /// A height of its own, for a row of them the board measures — the empty
    /// player's buttons are 22 tall (spec §4.8). Nil takes the padding's.
    var fixedHeight: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .islandFont(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            // Never a caption-sized target, whatever the word. At the body
            // role and these paddings every label is already larger, so this
            // changes no existing button; it is the floor for a short one.
            .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
            .frame(height: fixedHeight)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// A Settings row that is one switch: the label across the row, the track at
/// its trailing edge, and the whole of it the target.
///
/// Two things were wrong with `Toggle("", isOn:).toggleStyle(.switch)` and a
/// title beside it. AppKit draws its switch's on-state only in a key window,
/// and the panel is not key outside Translate, so on and off were told apart
/// by the knob's side alone (H-002). And the title was detached, so a click on
/// "Launch at Login" — the words — did nothing; only the 24×14 capsule at the
/// far edge flipped it (owner decision 2). Forcing the panel key to get the
/// active switch back would take the keyboard from whatever app the person is
/// typing in each time the pointer crossed the notch; the drawn switch asks
/// nothing of key status at all.
///
/// To an assistive client the row is still a plain switch: the drawn one is
/// replaced by a native `Toggle`, so VoiceOver reads its title, "switch" and
/// on or off, and its press is the same flip a click makes.
struct PanelSwitchStyle: ToggleStyle {
    /// What a state looks like, apart from any drawing, so the rule — that
    /// colour and edge depend on the state and Increase Contrast and on
    /// nothing else — is something a test can read.
    struct Look: Equatable {
        enum Track: Equatable { case accent, well }
        enum Knob: Equatable { case leading, trailing }
        var track: Track
        var knob: Knob
        var outlineWidth: CGFloat
    }

    static func look(isOn: Bool, increaseContrast: Bool) -> Look {
        Look(
            track: isOn ? .accent : .well,
            knob: isOn ? .trailing : .leading,
            outlineWidth: increaseContrast ? 1 : 0
        )
    }

    /// The row's own height and inset, so the hit target is the row the card
    /// draws rather than the label's text.
    var rowHeight: CGFloat = 26
    var horizontalInset: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        PanelSwitch(configuration: configuration, rowHeight: rowHeight, horizontalInset: horizontalInset)
    }
}

private struct PanelSwitch: View {
    let configuration: ToggleStyleConfiguration
    let rowHeight: CGFloat
    let horizontalInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = PanelSwitchStyle.look(
            isOn: configuration.isOn, increaseContrast: SystemAppearance.shared.increaseContrast
        )
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                track(look)
            }
            .padding(.horizontal, horizontalInset)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        // A plain `Toggle`, not one styled `.switch`: that one is AppKit's
        // NSSwitch again, which the probe found as a 56 pt checkbox with no
        // name beside a separate text, refusing the press. This one is a
        // single AXCheckBox (subrole AXToggle) the width of the row, named by
        // the label and carrying 0 or 1.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(_ look: PanelSwitchStyle.Look) -> some View {
        let size = Theme.switchTrackSize
        let travel = (size.width - size.height) / 2
        return Capsule(style: .continuous)
            .fill(look.track == .accent ? Theme.switchOnFill : Theme.switchOffFill)
            .overlay {
                // The hairline is the off well's edge, the only thing that
                // makes a recess read as a shape; on, the accent is its own.
                // Increase Contrast replaces either with a defined border.
                if look.outlineWidth > 0 {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.switchContrastOutline, lineWidth: look.outlineWidth)
                } else if look.track == .well {
                    Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .overlay {
                Circle()
                    .fill(Theme.switchKnob)
                    .frame(width: Theme.switchKnobDiameter, height: Theme.switchKnobDiameter)
                    .shadow(color: Theme.switchKnobShadow, radius: 1, y: 0.5)
                    .offset(x: look.knob == .trailing ? travel : -travel)
            }
            .frame(width: size.width, height: size.height)
            // Reduce Motion keeps the change and drops the travel: the knob
            // is simply on the other side.
            .animation(reduceMotion ? nil : Theme.contentAnimation, value: configuration.isOn)
    }
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? Theme.TypeRole.title.font(weight: .medium) : Theme.TypeRole.subhead.font())
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }

    /// One end of a travelling object, when there is a namespace to travel in.
    ///
    /// The namespace is optional because the views that carry these ids are also
    /// rendered on their own — `MediaPane` by the layout tests, with no panel
    /// around it and nothing to travel to. `matchedGeometryEffect` has no
    /// tolerant form: it takes a `Namespace.ID`, not an optional, so the choice
    /// has to be made here rather than at every call site.
    ///
    /// Apply this **inside** the fixed frame that declares the end's size, never
    /// outside it. Outside, the effect proposes the other end's size to a frame
    /// that is already pinned to its own, so the cover moves without ever
    /// growing — a hero animation that silently loses half its job.
    @ViewBuilder
    func morph(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Replaces one SF Symbol with the next the way Apple's own controls do,
    /// whenever `value` changes, and cuts under Reduce Motion.
    ///
    /// A symbol content transition only plays inside an animated transaction;
    /// in a plain one the glyph is simply swapped. Play/pause flips when the
    /// player says so (the helper's stream, a media key) and the Liked Songs
    /// heart when the library answers, both outside any `withAnimation`, so the
    /// most-watched control in the app could hard-cut beside a comment saying
    /// it was replaced (F-046). The repeat toggle animated `isOn`, which stays
    /// true from "all" to "one" while the glyph changes. Carrying the
    /// animation here, on the value that moves the glyph, means a caller
    /// cannot ask for the replace without the transaction that runs it.
    ///
    /// The fade of a tint that changes with the same value rides along; under
    /// Reduce Motion that is all that is left, since a fade is not motion.
    /// `MotionValuesTests.testEverySymbolSwapCarriesItsAnimation` keeps the
    /// bare transition out of the sources.
    func symbolSwap<Value: Equatable>(value: Value, reduceMotion: Bool) -> some View {
        contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            .animation(Theme.contentAnimation, value: value)
    }
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

extension View {
    /// The system font at a size, with the tracking that size actually wants.
    ///
    /// Everything drawn here used `.system(size:weight:)` bare, which takes
    /// Apple's font and leaves its tracking table behind — the one thing that
    /// keeps type looking deliberate as it changes size.
    func islandFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
            .tracking(Theme.tracking(forSize: size))
    }

    /// The same, by role. An explicit weight wins; left out, the role's own
    /// weight applies — which means a call site that used to say nothing, and
    /// so read as regular, must keep saying `.regular` out loud.
    func islandFont(_ role: Theme.TypeRole, weight: Font.Weight? = nil) -> some View {
        islandFont(role.size, weight: weight ?? role.weight)
    }
}

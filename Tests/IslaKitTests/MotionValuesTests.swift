import SwiftUI
import XCTest
@testable import IslaKit

/// Motion values, held to Apple's own rule.
final class MotionValuesTests: XCTestCase {

    /// From *Designing Fluid Interfaces*: damping starts at 1.0, and overshoot
    /// is added **only** when the gesture carried momentum. Nothing inside a
    /// surface is thrown, so nothing listed here should bounce. The island's
    /// outline is the one named exception (spec §19.3), held below.
    ///
    /// Asserted as the description string because `Animation` exposes no
    /// parameters to read back. Crude, and still the only thing standing
    /// between this file and a bounce creeping back in.
    func testNothingWithoutMomentumOvershoots() {
        for animation in Theme.criticallyDampedSprings {
            let described = String(describing: animation)
            XCTAssertTrue(
                described.contains("dampingFraction: 1.0"),
                "critically damped, per Apple's default: \(described)"
            )
        }
    }

    // MARK: The island's outline (spec §19.3)

    /// Response 0.5, damping 0.75: about 3 % past its end, once.
    func testTheOutlineSpringsOnPointFiveAndPointSevenFive() throws {
        XCTAssertEqual(Theme.islandResponse, 0.5)
        XCTAssertEqual(Theme.islandDamping, 0.75)
        XCTAssertEqual(Theme.islandSpring, Animation.spring(response: 0.5, dampingFraction: 0.75))

        let curve = try XCTUnwrap(LabCurve.parse(Theme.islandSpring, name: "island", usedFor: "", source: ""))
        XCTAssertEqual(curve.kind, .spring)
        XCTAssertEqual(curve.response, 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.damping, 0.75, accuracy: 1e-9)
        let samples = stride(from: 0.0, through: 2.0, by: 0.001).map { curve.sample($0).value }
        let peak = samples.max() ?? 0
        XCTAssertEqual(peak - 1, 0.028, accuracy: 0.002, "about 3 % past its end")
        // One swing: after the first return, nothing visible.
        let firstReturn = try XCTUnwrap(samples.indices.first { $0 > 400 && samples[$0] <= 1 })
        let laterExcess = samples[firstReturn...].map { abs($0 - 1) }.max() ?? 0
        XCTAssertLessThan(laterExcess, 0.001, "the return swing is under a tenth of a percent")
        // Quicker off the mark than the 0.34 critically damped open it replaced.
        XCTAssertLessThan(
            Theme.springRiseTime(response: Theme.islandResponse, damping: Theme.islandDamping, level: 0.99),
            Theme.springRiseTime(response: Theme.openResponse, damping: 1, level: 0.99)
        )
    }

    /// Every change of the outline's size rides it: opening, closing a beat
    /// late, the pill's fold and unfold and its content, the pop-up, and the
    /// body growing or folding — and none of them under Reduce Motion.
    func testEveryChangeOfTheOutlinesSizeRidesTheIslandSpring() throws {
        XCTAssertEqual(Theme.island(reduceMotion: false), Theme.islandSpring)
        XCTAssertEqual(Theme.open(reduceMotion: false), Theme.islandSpring)
        XCTAssertEqual(Theme.pill(reduceMotion: false), Theme.islandSpring)
        XCTAssertEqual(
            String(describing: Theme.close(reduceMotion: false)),
            String(describing: Theme.islandSpring.delay(Theme.closeShapeDelay))
        )
        XCTAssertEqual(PlayerLayout.animation(from: .column, to: .tall, reduceMotion: false), Theme.islandSpring)
        XCTAssertEqual(Theme.island(reduceMotion: true), Theme.reducedMotion)

        // The shell's own sites, read from the source because the curve a
        // transaction carries cannot be observed from outside a render.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/Notch/NotchController.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains(".animation(Theme.island(reduceMotion: reduceMotion), value: vm.openBodySize.height)"))
        XCTAssertTrue(shell.contains(".animation(Theme.island(reduceMotion: reduceMotion), value: vm.hud != nil)"))
        XCTAssertFalse(shell.contains("withAnimation(Theme.expand("), "the body's Expand moves the outline")
        XCTAssertTrue(controller.contains("withAnimation(Theme.island(reduceMotion: reduceMotion)) {\n                vm.isPeeking = false\n                vm.ambient = nil\n                vm.hud = moment"))
    }

    /// The outline's curves left the critically damped list; every curve that
    /// moves something inside a surface is still on it.
    func testOnlyTheOutlineLeftTheCriticallyDampedList() {
        let listed = Theme.criticallyDampedSprings.map { String(describing: $0) }
        XCTAssertFalse(listed.contains(String(describing: Theme.islandSpring)))
        XCTAssertFalse(listed.contains(String(describing: Theme.closeAnimation)), "the close is the outline's spring, late")
        for (name, curve) in [
            ("open, inside a surface", Theme.openAnimation), ("compact", Theme.compactAnimation),
            ("caption out", Theme.captionTurnOut), ("caption in", Theme.captionTurnIn),
            ("update card", Theme.expandAnimation), ("lock card", Theme.lockCardMorph),
        ] {
            XCTAssertTrue(listed.contains(String(describing: curve)), name)
        }
        XCTAssertEqual(listed.count, 6)
    }

    // MARK: Content arriving (spec §19.3)

    func testExpandedContentArrivesFromBlurThirtyAndAPoint() {
        XCTAssertEqual(
            IslandArrival.expanded(reduceMotion: false),
            IslandArrival(opacity: 0, blur: 30, scale: CGSize(width: 0.6, height: 0.2), anchor: UnitPoint(x: 0.5, y: 0.4))
        )
        XCTAssertEqual(IslandArrival.arrived(anchor: IslandArrival.expandedAnchor).anchor, UnitPoint(x: 0.5, y: 0.4),
                       "both ends scale about one point")
    }

    func testCompactContentArrivesFromBlurFifteenAndFourFifthsOfItsWidth() {
        XCTAssertEqual(
            IslandArrival.compact(reduceMotion: false),
            IslandArrival(opacity: 0, blur: 15, scale: CGSize(width: 0.8, height: 1), anchor: .center)
        )
        XCTAssertEqual(IslandArrival.arrived(), IslandArrival(opacity: 1, blur: 0, scale: CGSize(width: 1, height: 1), anchor: .center))
        XCTAssertEqual(PillPresence.appearance(shown: false, reduceMotion: false), .compact(reduceMotion: false),
                       "the pill's content is a compact activity's")
    }

    /// Reduce Motion still means no spring at all, which no damping value fixes.
    func testReduceMotionReplacesTheSpringEntirely() {
        let reduced = String(describing: Theme.open(reduceMotion: true))
        XCTAssertFalse(reduced.contains("spring"), "a spring is travel, and that is what was refused")
    }

    /// Reduce Motion never jumps on its first frame (F-055).
    ///
    /// Every reduced variant used to be an ease-out of 0.12 or 0.15 s. An
    /// ease-out leaves at its fastest, so the reduced open moved 38.6 pt in
    /// its first frame and peaked at 2,518 pt/s — twice the 1,197 pt/s of the
    /// spring it replaces. The people who asked for calm got the fastest,
    /// most abrupt path in the app. One ease-in-out of 0.24 s now stands for
    /// every travel the setting keeps: zero speed at both ends, a peak of
    /// about 1,264 pt/s over the panel's 176 pt, and 1.7 pt in the first
    /// frame at 60 Hz.
    ///
    /// Asserted twice: by description, so a variant cannot quietly grow its
    /// own curve, and by sampling the curve SwiftUI actually built (the
    /// visual lab's parser), so the numbers above are the ones on screen.
    func testReduceMotionNeverJumpsTheFirstFrame() throws {
        let reduced = String(describing: Theme.reducedMotion)
        let variants: [(String, Animation)] = [
            ("open", Theme.open(reduceMotion: true)),
            ("close", Theme.close(reduceMotion: true)),
            ("compact", Theme.compact(reduceMotion: true)),
            ("pill fold and unfold", Theme.pill(reduceMotion: true)),
            ("the outline", Theme.island(reduceMotion: true)),
            ("lyric page", Theme.lyricScroll(reduceMotion: true)),
            ("hover nudge", Theme.hoverNudge(reduceMotion: true)),
        ]
        for (name, animation) in variants {
            XCTAssertEqual(String(describing: animation), reduced, "\(name) has a reduced curve of its own")
        }
        XCTAssertEqual(reduced, String(describing: Animation.easeInOut(duration: 0.24)),
                       "an ease-in-out: no speed at either end")

        let travel = 176.0
        let curve = try XCTUnwrap(LabCurve.parse(Theme.reducedMotion, name: "reduced", usedFor: "", source: ""))
        let firstFrame = curve.sample(1.0 / 60).value * travel
        XCTAssertLessThan(firstFrame, 2, "the first frame jumped \(firstFrame) pt")
        let peak = stride(from: 0.0, through: 0.24, by: 0.001)
            .map { abs(curve.sample($0).velocity) * travel }.max() ?? 0
        XCTAssertLessThan(peak, 1_300, "peaks at \(peak) pt/s, faster than the spring it stands in for")
        XCTAssertLessThan(abs(curve.sample(0.0005).velocity) * travel, 20, "it starts from rest")
    }

    /// The tab swap fades and does not zoom under Reduce Motion (F-017).
    ///
    /// The pane swap built its 0.97 in, 1.02 out scale inline, beside a
    /// `Theme.scaleIn(_:reduceMotion:)` that exists for exactly this, so every
    /// tab switch still zoomed with the setting on.
    func testTheTabSwapOnlyFadesUnderReduceMotion() {
        let reduced = Theme.paneSwapScales(reduceMotion: true)
        XCTAssertEqual(reduced.insertion, 1)
        XCTAssertEqual(reduced.removal, 1)
        let full = Theme.paneSwapScales(reduceMotion: false)
        XCTAssertEqual(full.insertion, 0.97)
        XCTAssertEqual(full.removal, 1.02)
    }

    /// Under Reduce Motion the cover and the equalizer do not fly between the
    /// pill and the panel: they fade with the pane they belong to (F-055).
    @MainActor
    func testNothingTravelsUnderReduceMotion() {
        XCTAssertFalse(NotchContentView.travels(reduceMotion: true))
        XCTAssertTrue(NotchContentView.travels(reduceMotion: false))
    }

    /// The page is carried by the song, so this is the one animation in the app
    /// entitled to overshoot: the words have momentum the way a flick does. It
    /// also has to be slower than the sweep it carries — borrowing the generic
    /// 0.16s content ease made the page arrive before the voice did.
    func testTheLyricScrollIsSlowerThanTheWordSweepAndMayOvershoot() {
        XCTAssertGreaterThan(Theme.lyricScrollResponse, 0.25,
                             "the page must not outrun the word sweep it carries")
        XCTAssertLessThan(Theme.lyricScrollDamping, 1.0,
                          "carried by momentum, so a small overshoot is correct here")
        XCTAssertGreaterThan(Theme.lyricScrollDamping, 0.75,
                             "a small overshoot, not a wobble")
    }

    /// The caption's line turn stays inside its slot. The travel is clipped at
    /// the slot's edge, so a travel past half the slot would have the arriving
    /// line cut off mid-glyph before it settled; and it is a real travel, not a
    /// crossfade wearing an offset — under 3 pt reads as a shiver.
    @MainActor
    func testTheLineTurnTravelsWithinTheCaptionSlot() {
        XCTAssertLessThan(LyricLineTurn.travel, MediaPane.captionHeight / 2,
                          "the turn must settle before the clip takes it")
        XCTAssertGreaterThanOrEqual(LyricLineTurn.travel, 3, "a turn, not a shiver")
        // Both ends of the modifier: gone and arrived.
        XCTAssertEqual(LyricLineTurn(progress: 1, direction: 1).progress, 1)
        XCTAssertEqual(LyricLineTurn(progress: 0, direction: -1).progress, 0)
    }

    /// The caption's line turn never prints two legible lines on top of each
    /// other (H-014).
    ///
    /// Both lines used to ride the one lyric spring (0.42 s, ζ 0.86), so the
    /// line leaving and the line arriving crossed at the same moment: from 62
    /// to 158 ms both were at least a quarter opaque, under up to 3 pt of
    /// blur, and the visual lab's keyframes t083–t200 showed the smear on
    /// every line. Now the outgoing line leaves on a quick spring of its own
    /// and the incoming one follows behind a short delay, the same out-fast,
    /// in-behind rule the pill's content uses.
    ///
    /// Read from the closed form of a critically damped spring started at
    /// rest — what is left of the travel at t is `e^(−ωt)(1 + ωt)`, ω =
    /// 2π/response — scanned in 1 ms steps over the whole turn. The opacity
    /// of `LyricLineTurn` is `1 − progress`, so the outgoing line's opacity
    /// *is* that remainder and the incoming line's is its complement.
    func testTheCaptionTurnNeverOverprints() {
        func remaining(_ t: Double, response: Double) -> Double {
            guard t > 0 else { return 1 }
            let omega = 2 * Double.pi / response
            return exp(-omega * t) * (1 + omega * t)
        }
        func outgoing(_ t: Double) -> Double { remaining(t, response: Theme.captionTurnOutResponse) }
        func incoming(_ t: Double) -> Double {
            1 - remaining(t - Theme.captionTurnInDelay, response: Theme.captionTurnInResponse)
        }

        let overprinted = (0...600).map { Double($0) / 1000 }.filter { t in
            outgoing(t) >= 0.25 && incoming(t) >= 0.25
        }
        XCTAssertTrue(overprinted.isEmpty,
                      "both lines at least a quarter opaque for \(overprinted.count) ms, from \(overprinted.first ?? 0) s")
        XCTAssertGreaterThanOrEqual(incoming(0.120), 0.5, "the new line is legible by 120 ms")
        XCTAssertLessThan(outgoing(0.120), 0.1, "and the old one is all but gone by then")
        XCTAssertLessThanOrEqual(LyricLineTurn.maxBlur, 2,
                                 "a turn softens the line; 3 pt smeared it")
        // Out faster than in, or the old line is still there when the new
        // one lands on it.
        XCTAssertLessThan(Theme.captionTurnOutResponse, Theme.captionTurnInResponse)
        XCTAssertGreaterThan(Theme.captionTurnInDelay, 0)
    }

    /// The published position is what a lyric reads, so the tick interval *is*
    /// how stale the words on screen can be — not merely how smoothly the
    /// scrubber advances.
    ///
    /// Measured, not reasoned: at the old quarter-second the live Spotify probe
    /// put the lyric surface's 95th-percentile error at 0.167 s against a
    /// 0.150 s gate, with a bias near zero — the whole failure was the spread
    /// this interval creates. At a tenth of a second the same run measured
    /// 0.074 s and 0.083 s. The lead can only centre the error; only this can
    /// narrow it, so the two together must stay under the gate.
    @MainActor
    func testThePositionTickIsFineEnoughForTheWordTimingGate() {
        XCTAssertLessThanOrEqual(
            MediaController.positionTickInterval, 0.1,
            "a coarser tick puts the lyric surface's p95 back over the 150ms gate"
        )
        // And the lead is what centres the residual. The probe measured the
        // clock a median 0.188 s behind; the lead must stay within a tick of
        // cancelling that, or the bias re-opens what the interval just closed.
        XCTAssertEqual(
            LyricSweep.standardLead, 0.20, accuracy: 0.05,
            "the lead centres the measured lag; re-run Scripts/measure-sync.sh before moving it"
        )
    }

    /// Every symbol replace carries the animation that makes it run (F-046).
    ///
    /// `.contentTransition(.symbolEffect(.replace))` only plays inside an
    /// animated transaction. Play/pause flips when the player says so, from
    /// the helper's stream or a media key, and the Liked Songs heart when the
    /// library answers: plain transactions both, so the most-watched glyph in
    /// the app could hard-cut while its comment said it was replaced. The
    /// transition was written bare at nine sites, and each one had to remember
    /// an `.animation(value:)` of its own; the two transports and the heart
    /// did not, and the repeat toggle animated `isOn`, which stays on from
    /// "all" to "one" while the glyph changes. `View.symbolSwap(value:
    /// reduceMotion:)` pairs the two by construction, and this scan holds the
    /// bare form out of the sources, the way `test-branding.sh` holds a name
    /// out: brittle by design.
    func testEverySymbolSwapCarriesItsAnimation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources found under \(sources.path)")

        var text: [String: String] = [:]
        for file in files {
            text[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }

        // The replace is spelled once, inside the helper, and nowhere else.
        for (name, body) in text.sorted(by: { $0.key < $1.key }) {
            let replaces = body.components(separatedBy: ".symbolEffect(.replace").count - 1
            XCTAssertEqual(
                replaces, name == "Theme.swift" ? 1 : 0,
                "\(name) spells a symbol replace by hand; use .symbolSwap(value:reduceMotion:)"
            )
        }

        // And the sites F-046 named go through it with the value that moves.
        let sites: [(file: String, call: String)] = [
            ("MediaPane.swift", ".symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)"),
            ("LockScreenCard.swift", ".symbolSwap(value: media.isPlaying, reduceMotion: reduceMotion)"),
            ("LockScreenCard.swift", ".symbolSwap(value: isSaved, reduceMotion: reduceMotion)"),
            ("LockScreenCard.swift", ".symbolSwap(value: symbol, reduceMotion: reduceMotion)"),
            ("ClipboardPane.swift", ".symbolSwap(value: justCopied, reduceMotion: reduceMotion)"),
            ("ModeToggle.swift", ".symbolSwap(value: symbol, reduceMotion: reduceMotion)"),
        ]
        for site in sites {
            XCTAssertTrue(
                text[site.file]?.contains(site.call) == true,
                "\(site.file) does not replace its glyph with \(site.call)"
            )
        }
    }
}

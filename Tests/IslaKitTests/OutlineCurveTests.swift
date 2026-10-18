import SwiftUI
import XCTest
@testable import IslaKit

/// The curve the island's outline rides is read back from the animation SwiftUI
/// hands each change (`OutlineCurve.of`), and sampled with SwiftUI's own
/// solver. These pin both ends: that every animation the shell and the
/// controller can hand it is *read* (not defaulted), and that what is read
/// moves the way the spec says (§19.3).
final class OutlineCurveTests: XCTestCase {
    // MARK: Reading

    func testTheOutlinesOwnSpringIsRead() {
        XCTAssertEqual(
            OutlineCurve.of(Theme.islandSpring),
            .spring(response: 0.5, damping: 0.75, delay: 0),
            "response 0.5, damping 0.75 (§19.3)"
        )
        XCTAssertEqual(OutlineCurve.island, .spring(response: Theme.islandResponse, damping: Theme.islandDamping, delay: 0))
    }

    func testTheCloseKeepsItsThirtyMillisecondDelay() {
        XCTAssertEqual(
            OutlineCurve.of(Theme.closeAnimation),
            .spring(response: 0.5, damping: 0.75, delay: Theme.closeShapeDelay),
            "the shape waits for the body to leave (H-012)"
        )
    }

    func testThePopUpAndTheHoverNudgeKeepTheirOwnSprings() {
        XCTAssertEqual(OutlineCurve.of(Theme.hudSpring), .spring(response: 0.3, damping: 1.0, delay: 0))
        XCTAssertEqual(
            OutlineCurve.of(Theme.hoverNudge),
            .spring(response: 0.34, damping: Theme.hoverNudgeDamping, delay: 0)
        )
    }

    func testReduceMotionIsTheEaseInOutWithNoOvershoot() throws {
        for reduce in [true] {
            guard case .bezier(let duration, let cubic, let delay) = OutlineCurve.of(Theme.island(reduceMotion: reduce)) else {
                return XCTFail("Reduce Motion's outline is a timing curve")
            }
            XCTAssertEqual(duration, Theme.reducedMotionDuration, accuracy: 1e-9)
            XCTAssertEqual(delay, 0)
            // Never past its end, however finely it is sampled.
            let samples = stride(from: 0.0, through: duration, by: duration / 200).map { cubic.y(cubic.solve(x: $0 / duration)) }
            XCTAssertLessThanOrEqual(samples.max() ?? 2, 1 + 1e-9)
            XCTAssertEqual(samples.last ?? 0, 1, accuracy: 1e-6)
        }
    }

    /// Every animation that can reach the outline's change of size, by the
    /// shell's `.animation` modifiers and the controller's `withAnimation`
    /// calls, is read to a curve and not defaulted: a defaulted one would
    /// still move, on the wrong curve, with nothing to say so.
    func testEveryAnimationTheShellAndTheControllerUseIsRead() {
        let reducing = [true, false]
        var animations: [(String, Animation)] = [
            ("contentAnimation", Theme.contentAnimation),
            ("paneAnimation", Theme.paneAnimation),
            ("compactAnimation", Theme.compactAnimation),
            ("openAnimation", Theme.openAnimation),
            ("closeAnimation", Theme.closeAnimation),
            ("islandSpring", Theme.islandSpring),
            ("hudSpring", Theme.hudSpring),
            ("hoverNudge", Theme.hoverNudge),
            ("reducedMotion", Theme.reducedMotion),
        ]
        for reduce in reducing {
            animations += [
                ("island(\(reduce))", Theme.island(reduceMotion: reduce)),
                ("open(\(reduce))", Theme.open(reduceMotion: reduce)),
                ("close(\(reduce))", Theme.close(reduceMotion: reduce)),
                ("pill(\(reduce))", Theme.pill(reduceMotion: reduce)),
                ("hud(\(reduce))", Theme.hud(reduceMotion: reduce)),
                ("hoverNudge(\(reduce))", Theme.hoverNudge(reduceMotion: reduce)),
            ]
        }
        for (name, animation) in animations {
            XCTAssertNotNil(OutlineCurve.parse(String(describing: animation)), "\(name) is not readable: \(animation)")
        }
    }

    func testNoAnimationOrADisabledOneIsInstant() {
        XCTAssertEqual(OutlineCurve.of(nil), .instant)
        XCTAssertEqual(OutlineCurve.of(Theme.islandSpring, disablesAnimations: true), .instant, "the lock is a cut")
    }

    func testAnAnimationNobodyCanReadIsTheOutlinesOwn() {
        XCTAssertNil(OutlineCurve.parse("SomethingNew()"))
        XCTAssertEqual(OutlineCurve.of(.default), .island)
    }

    // MARK: Moving

    /// The sampler follows SwiftUI's solver, which the visual lab already
    /// checks against the damped oscillator's closed form.
    func testTheSpringFollowsTheClosedForm() throws {
        let curve = try XCTUnwrap(LabCurve.parse(Theme.islandSpring, name: "island", usedFor: "", source: ""))
        let outline = OutlineCurve.of(Theme.islandSpring)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(outline.progress(at: t), curve.closedForm(t), accuracy: 1e-6, "t = \(t)")
        }
    }

    func testTheIslandOvershootsByAboutThreePercentAndThenSettles() {
        let (duration, progress) = OutlineCurve.island.keyframes()
        let peak = progress.max() ?? 0
        XCTAssertEqual(peak, 1.03, accuracy: 0.006, "§19.3: about 3 %")
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1, "the last keyframe is exactly the target")
        XCTAssertLessThan(duration, 1.2, "it is within 0.0004 of rest inside a second or so")
        XCTAssertGreaterThan(duration, 0.5)
        // Rising until the peak, then falling back, and once.
        let top = progress.firstIndex(of: peak) ?? 0
        XCTAssertTrue(zip(progress[0...top], progress[0...top].dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testTheCloseHoldsStillForItsDelay() {
        let (_, progress) = OutlineCurve.of(Theme.closeAnimation).keyframes()
        let held = Int((Theme.closeShapeDelay * OutlineCurve.sampleRate).rounded(.down))
        XCTAssertTrue(progress[0..<max(1, held)].allSatisfy { $0 == 0 }, "nothing moves for the first 30 ms")
        XCTAssertGreaterThan(progress[held + 2], 0)
    }

    func testTheReducedCurveEndsExactlyAtItsDuration() {
        let (duration, progress) = OutlineCurve.of(Theme.reducedMotion).keyframes()
        XCTAssertEqual(duration, Theme.reducedMotionDuration, accuracy: 1 / OutlineCurve.sampleRate)
        XCTAssertEqual(progress.last, 1)
        XCTAssertLessThanOrEqual(progress.max() ?? 2, 1 + 1e-9, "no overshoot under Reduce Motion")
    }

    func testAnInterruptedSpringKeepsItsMomentum() {
        let spring = OutlineCurve.island
        XCTAssertGreaterThan(spring.progress(at: 0.03, initialVelocity: 4), spring.progress(at: 0.03), "carried forward")
        XCTAssertLessThan(spring.progress(at: 0.03, initialVelocity: -4), spring.progress(at: 0.03), "carried backward")
        // A timing curve starts again from rest, as SwiftUI's do.
        let ease = OutlineCurve.of(Theme.reducedMotion)
        XCTAssertEqual(ease.progress(at: 0.05, initialVelocity: 4), ease.progress(at: 0.05))
    }

    func testVelocityIsTheDerivativeOfProgress() {
        for curve in [OutlineCurve.island, OutlineCurve.of(Theme.reducedMotion), OutlineCurve.of(Theme.hudSpring)] {
            for t in [0.05, 0.1, 0.2] {
                let h = 1e-4
                let numeric = (curve.progress(at: t + h) - curve.progress(at: t - h)) / (2 * h)
                XCTAssertEqual(curve.velocity(at: t), numeric, accuracy: 0.02, "\(curve) at \(t)")
            }
        }
    }

    func testAnInstantChangeIsOneKeyframe() {
        let (duration, progress) = OutlineCurve.instant.keyframes()
        XCTAssertEqual(duration, 0)
        XCTAssertEqual(progress, [1])
    }
}

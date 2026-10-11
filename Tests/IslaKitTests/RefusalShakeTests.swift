import XCTest
@testable import IslaKit

/// The locked island's refusal. The shake almost certainly never played: the
/// locked branch's `.transaction { $0.animation = nil }` wiped the
/// `withAnimation` that drove it, and a second click from a resting progress
/// of 1 netted no change (F-018). It is time-driven now, so these samples are
/// the whole motion.
final class RefusalShakeTests: XCTestCase {

    /// Gentle in, equal beats, settled at the end. The old ease-out progress
    /// threw an 8.8 pt jump in the first frame and a beat that halved.
    func testTheShakeStartsGentlyAndKeepsItsBeat() {
        let duration = RefusalShake.duration
        XCTAssertEqual(RefusalShake.offset(at: 0), 0)
        XCTAssertLessThanOrEqual(abs(RefusalShake.offset(at: 1.0 / 60)), 3, "the first frame must not jump")
        XCTAssertEqual(RefusalShake.offset(at: duration), 0, accuracy: 1e-9)
        XCTAssertEqual(RefusalShake.offset(at: duration + 1), 0, "after the shake it is still")
        XCTAssertEqual(RefusalShake.offset(at: -1), 0, "before the shake it is still")

        // Equal half-periods: the sign flips at k · duration / (2 · shakes).
        let half = duration / (2 * RefusalShake.shakes)
        for k in 1..<Int(2 * RefusalShake.shakes) {
            let at = Double(k) * half
            let before = RefusalShake.offset(at: at - 0.002)
            let after = RefusalShake.offset(at: at + 0.002)
            XCTAssertLessThan(before * after, 0, "no zero crossing near \(at) s")
        }

        var peak = 0.0
        for ms in 0...600 { peak = max(peak, abs(RefusalShake.offset(at: Double(ms) / 1000))) }
        XCTAssertLessThanOrEqual(peak, Double(RefusalShake.standardAmplitude))
    }

    /// Under Reduce Motion the refusal used to be removed entirely, so a
    /// locked click answered with nothing. A dip says the same thing without
    /// moving anything: the pill's content dims and comes back.
    func testReduceMotionDipsInsteadOfMoving() {
        let length = RefusalShake.reducedDuration
        XCTAssertEqual(RefusalShake.reducedOpacity(at: 0), 1)
        XCTAssertLessThanOrEqual(RefusalShake.reducedOpacity(at: length / 2), 0.5)
        XCTAssertEqual(RefusalShake.reducedOpacity(at: length), 1, accuracy: 1e-9)
        XCTAssertEqual(RefusalShake.reducedOpacity(at: length + 1), 1)
        XCTAssertLessThanOrEqual(length, RefusalShake.duration, "the dip is over before the shake would be")
    }

    /// A folded pill has nowhere to swing: an amplitude of zero keeps the
    /// modifier, and with it the view's identity, without moving.
    func testAZeroAmplitudeDoesNotMove() {
        XCTAssertEqual(RefusalShake.offset(at: 0.1, amplitude: 0), 0)
    }
}

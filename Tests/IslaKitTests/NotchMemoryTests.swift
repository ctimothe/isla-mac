import AppKit
import XCTest
@testable import IslaKit

/// What a display that has always had a notch is allowed to say about itself.
///
/// A reconfiguration — waking, unlocking, a mode change, a display arriving
/// beside this one — can leave `safeAreaInsets` reading zero for a beat on a
/// Mac whose cutout has not gone anywhere. Believed, that reading rebuilds the
/// panel around a synthetic notch: a smaller pill anchored to the middle of the
/// screen rather than to the hardware, which then stays until the next
/// notification happens to arrive. Locking and unlocking is the one that
/// reliably does, which is exactly how it presents — "it fixes itself if I lock
/// the screen".
final class NotchMemoryTests: XCTestCase {
    private let cutout = CGSize(width: 185, height: 32)
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAFreshNotchReadingIsAlwaysBelieved() {
        let decision = NotchGeometry.decide(
            reading: .physical(size: cutout, centerX: 756),
            screenFrame: screen,
            remembered: nil
        )
        XCTAssertEqual(decision, .physical(size: cutout, centerX: 756))
    }

    func testTheNotchIsNotForgottenWhileTheDisplayIsUnchanged() {
        // Same display, same frame, and it reported a cutout a moment ago: the
        // zero reading is the glitch, not the hardware.
        let decision = NotchGeometry.decide(
            reading: .none,
            screenFrame: screen,
            remembered: .init(frame: screen, size: cutout, centerX: 756)
        )
        XCTAssertEqual(decision, .physical(size: cutout, centerX: 756))
    }

    func testARealModeChangeIsBelieved() {
        // The display genuinely changed shape — a non-HiDPI mode, where macOS
        // stops vending a safe area at all and a drawn notch is correct.
        let scaled = CGRect(x: 0, y: 0, width: 3024, height: 1890)
        let decision = NotchGeometry.decide(
            reading: .none,
            screenFrame: scaled,
            remembered: .init(frame: screen, size: cutout, centerX: 756)
        )
        XCTAssertEqual(decision, NotchGeometry.NotchReading.none)
    }

    func testADisplayThatNeverHadANotchStaysSynthetic() {
        let decision = NotchGeometry.decide(
            reading: .none,
            screenFrame: screen,
            remembered: nil
        )
        XCTAssertEqual(decision, NotchGeometry.NotchReading.none)
    }
}

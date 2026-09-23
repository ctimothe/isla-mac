import XCTest
@testable import IslaKit

/// The notch panel and the lock card share one SkyLight space above the
/// shield. The space has to outlive whichever of them leaves first, and go
/// when the last one does.
@MainActor
final class LockSpaceTests: XCTestCase {

    private final class Recorder {
        var created = 0
        var destroyed: [UInt64] = []
        var hidden: [UInt64] = []
        var removed: [Int] = []
        var added: [Int] = []
    }

    private func skyLight(_ recorder: Recorder) -> SkyLight {
        SkyLight(calls: .init(
            create: { recorder.created += 1; return UInt64(100 + recorder.created) },
            destroy: { recorder.destroyed.append($0) },
            setLevel: { _, _ in },
            show: { _ in },
            hide: { recorder.hidden.append($0) },
            add: { _, window in recorder.added.append(window) },
            remove: { _, window in recorder.removed.append(window) }
        ))
    }

    /// Unlock lowers the card first. That used to destroy the space with the
    /// panel still in it, and the panel's own lower then did nothing.
    func testTheCardLeavingFirstKeepsTheSpaceForThePanel() {
        let recorder = Recorder()
        let sky = skyLight(recorder)
        sky.lift(windowNumber: 1)   // panel
        sky.lift(windowNumber: 2)   // card
        XCTAssertEqual(recorder.created, 1, "one space for both")

        sky.lower(windowNumber: 2)
        XCTAssertEqual(recorder.removed, [2])
        XCTAssertTrue(recorder.destroyed.isEmpty, "the panel is still in it")

        sky.lower(windowNumber: 1)
        XCTAssertEqual(recorder.removed, [2, 1], "the panel really leaves the space")
        XCTAssertEqual(recorder.destroyed, [101])
        XCTAssertEqual(recorder.hidden, [101])
        XCTAssertTrue(sky.windows.isEmpty)
    }

    func testTheNextLockGetsAFreshSpace() {
        let recorder = Recorder()
        let sky = skyLight(recorder)
        sky.lift(windowNumber: 1)
        sky.lower(windowNumber: 1)
        sky.lift(windowNumber: 1)
        XCTAssertEqual(recorder.created, 2)
    }

    /// Lowering a window that was never lifted must not tear down the space
    /// the others are in.
    func testAStrangerLoweringChangesNothing() {
        let recorder = Recorder()
        let sky = skyLight(recorder)
        sky.lift(windowNumber: 1)
        sky.lower(windowNumber: 9)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(recorder.destroyed.isEmpty)
    }
}

/// The screen-wake decision, which lived inline in `NotchController` and is
/// where fixes to the lock and wake path kept landing.
final class WakePlanTests: XCTestCase {
    func testAnOrdinaryWakeResumesEverything() {
        XCTAssertEqual(
            NotchController.wakePlan(isLocked: false, lockedPresentation: false),
            [.startWatchdog, .resumeStores, .restartPointer]
        )
    }

    /// The unlock notification was missed: replay it, and start nothing that
    /// the unlock itself will start.
    func testAWakeUnlockedButDressedForTheLockReplaysTheUnlock() {
        XCTAssertEqual(
            NotchController.wakePlan(isLocked: false, lockedPresentation: true),
            [.startWatchdog, .resumeStores, .repairUnlock]
        )
    }

    /// Mid-lock the sampler stays stopped and the stores stay quiet; only the
    /// card's clock comes back.
    func testAWakeUnderTheShieldRestartsOnlyTheCard() {
        XCTAssertEqual(
            NotchController.wakePlan(isLocked: true, lockedPresentation: true),
            [.startWatchdog, .reactivateCardMedia]
        )
        XCTAssertEqual(NotchController.wakePlan(isLocked: true, lockedPresentation: false), [.startWatchdog])
    }

    func testThePointerNeverRestartsWhileLocked() {
        for presentation in [false, true] {
            XCTAssertFalse(NotchController.wakePlan(isLocked: true, lockedPresentation: presentation).contains(.restartPointer))
            XCTAssertFalse(NotchController.wakePlan(isLocked: true, lockedPresentation: presentation).contains(.resumeStores))
        }
    }
}

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

// MARK: - The Prompter leaves nothing behind (plan T8, T13)

/// The suite's other half: not the notch's memory but the process's. A
/// Prompter session is the one thing in the panel that holds a power
/// assertion, a 20 Hz timer, a background layout of a page that can run to
/// megabytes, and a wheel watch's pending settle. Starting and stopping one,
/// and then letting the model go, must leave none of them, and nothing of the
/// session, its stage or its parts alive.
extension NotchMemoryTests {
    @MainActor
    func testStartingAndStoppingAPrompterSessionLeaksNothing() async throws {
        weak var session: PrompterSession?
        weak var stage: PrompterStageModel?
        weak var settings: PrompterSettings?
        weak var library: PrompterLibrary?
        weak var model: NotchViewModel?
        let rig: StageRig
        do {
            let fixture = try StartFixture()
            rig = fixture.rig
            try fixture.addScript([promptFixturePage(words: 3_000), "a second page"])
            XCTAssertEqual(fixture.vm.startPrompter(), .openStage)
            let liveStage = try XCTUnwrap(fixture.vm.prompterStage)
            liveStage.setViewport(CGSize(width: 532, height: 120))
            XCTAssertNotNil(liveStage.layout)
            fixture.rig.read(for: 1)
            liveStage.wheel(deltaY: -30, final: false)   // a settle left pending
            fixture.vm.stopPrompter()

            XCTAssertEqual(fixture.session.state, .ended)
            XCTAssertTrue(fixture.rig.scheduler.live.filter { $0.interval != nil }.isEmpty, "no tick left running")
            fixture.rig.scheduler.advance(by: 1)   // the settle, if any, finds nothing to do
            XCTAssertEqual(fixture.session.state, .ended)
            XCTAssertFalse(fixture.rig.lease.held, "the display-awake lease is let go")
            XCTAssertNil(liveStage.layout, "the page's layout is let go")
            XCTAssertEqual(liveStage.cachedLayoutCount, 0)
            XCTAssertNil(liveStage.layoutTask)

            session = fixture.session
            stage = liveStage
            settings = fixture.feature.parts?.settings
            library = fixture.feature.parts?.library
            model = fixture.vm
            fixture.feature.set(false)
            fixture.release()
        }
        // Let any task the run left finish unwinding before counting.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(session, "the session outlived the switch")
        XCTAssertNil(stage, "the stage model outlived its view model")
        XCTAssertNil(settings)
        XCTAssertNil(library)
        XCTAssertNil(model, "the view model outlived everything that held it")
        _ = rig
    }
}

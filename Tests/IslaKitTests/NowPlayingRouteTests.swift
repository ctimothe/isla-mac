import Foundation
import XCTest
@testable import IslaKit

/// When Now Playing cannot be read, the app says so, stops waiting for a
/// helper that will never speak, and tries again when that might help.
@MainActor
final class NowPlayingRouteTests: XCTestCase {

    /// The host script used to go straight on to its sleep loop after a
    /// refused load. That left a mute perl, 45 s of watchdog cycles before
    /// the fallback, and an orphan if the app died in between.
    func testTheHostScriptExitsWhenTheLoadIsRefused() {
        XCTAssertTrue(
            NowPlayingFeed.hostScript.contains("or exit \(NowPlayingFeed.loadRefusedExitStatus)"),
            NowPlayingFeed.hostScript
        )
    }

    /// The real perl, with a library that is not there: the load fails and
    /// the host must exit at once with the refused status, not sleep.
    func testPerlExitsWithTheRefusedStatusAtOnce() throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else {
            throw XCTSkip("no /usr/bin/perl on this machine")
        }
        let task = Process()
        task.executableURL = perl
        task.arguments = ["-e", NowPlayingFeed.hostScript, "/nonexistent/libislamedia-test.dylib"]
        task.standardError = FileHandle.nullDevice
        let exited = expectation(description: "perl exits")
        task.terminationHandler = { _ in exited.fulfill() }
        try task.run()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(task.terminationReason, .exit)
        XCTAssertEqual(task.terminationStatus, NowPlayingFeed.loadRefusedExitStatus)
        XCTAssertEqual(
            NowPlayingFeed.routeFailure(exitStatus: task.terminationStatus, reason: task.terminationReason),
            .readerRefused
        )
    }

    /// Only the script's own status is a verdict. A crash or a signal goes to
    /// the restart budget like before.
    func testOtherDeathsAreNotAVerdict() {
        XCTAssertNil(NowPlayingFeed.routeFailure(exitStatus: 1, reason: .exit))
        XCTAssertNil(NowPlayingFeed.routeFailure(exitStatus: 3, reason: .uncaughtSignal))
        XCTAssertNil(NowPlayingFeed.routeFailure(exitStatus: 0, reason: .exit))
    }

    func testTheFallbackNamesItsReason() {
        let media = MediaController()
        XCTAssertNil(media.fallbackReason)
        media.switchToScriptingFallback(.keptStopping)
        XCTAssertEqual(media.fallbackReason, .keptStopping)
        media.stop()
        XCTAssertNil(media.fallbackReason, "a stop returns the controller to Now Playing")
    }

    /// The fallback used to be one-way until quit.
    func testAWakeTriesNowPlayingAgain() {
        let media = MediaController()
        media.switchToScriptingFallback(.keptStopping)
        media.retryNowPlaying(userAsked: false)
        XCTAssertNil(media.fallbackReason)
        media.stop()
    }

    /// Each refused load raises macOS's "Not Opened" alert, so only the user
    /// may ask for another.
    func testARefusedLoadIsRetriedOnlyWhenAsked() {
        let media = MediaController()
        media.switchToScriptingFallback(.readerRefused)
        media.retryNowPlaying(userAsked: false)
        XCTAssertEqual(media.fallbackReason, .readerRefused, "a wake must not raise the alert again")
        media.retryNowPlaying(userAsked: true)
        XCTAssertNil(media.fallbackReason)
        media.stop()
    }

    /// With lyrics off nothing is drawing the tenth of a second the
    /// AppleScript poll buys, so it must not run.
    func testThePrecisionPollWaitsForLyrics() {
        let controller = MediaController()
        controller.precisionPlayerForTests = .music
        controller.lyricsShown = { false }
        controller.precisionPositionFetcher = { next in Task { @MainActor in next(42.3) } }
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.duration = 300
        playing.elapsed = 40
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)
        controller.setActive(true)
        XCTAssertFalse(controller.precisionSync)

        controller.lyricsShown = { true }
        controller.refreshPrecisionSync()
        XCTAssertTrue(controller.precisionSync)
        controller.setActive(false)
    }
}

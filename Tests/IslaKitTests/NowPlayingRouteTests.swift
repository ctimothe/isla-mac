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

    /// The fallback used to be one-way until quit. Now a wake tries again,
    /// and the fallback keeps working until the helper has proved itself.
    func testAWakeTriesAgainAndTheFallbackStaysUntilTheHelperSpeaks() {
        let media = MediaController()
        media.switchToScriptingFallback(.keptStopping)
        media.retryNowPlaying(userAsked: false)
        XCTAssertTrue(media.retryingNowPlaying)
        XCTAssertEqual(media.fallbackReason, .keptStopping, "Music and Spotify keep working meanwhile")

        var first = NowPlayingFeed.Snapshot()
        first.title = "Back"
        first.takenAt = Date()
        media.feedDelivered(first)
        XCTAssertNil(media.fallbackReason)
        XCTAssertFalse(media.retryingNowPlaying)
        media.stop()
    }

    /// A retry that fails leaves the fallback as it was, with the new reason.
    func testAFailedRetryKeepsTheFallback() {
        let media = MediaController()
        media.switchToScriptingFallback(.keptStopping)
        media.retryNowPlaying(userAsked: false)
        media.switchToScriptingFallback(.routeClosed)
        XCTAssertFalse(media.retryingNowPlaying)
        XCTAssertEqual(media.fallbackReason, .routeClosed)
        media.stop()
    }

    /// Each refused load raises macOS's "Not Opened" alert, so only the user
    /// may ask for another.
    func testARefusedLoadIsRetriedOnlyWhenAsked() {
        let media = MediaController()
        media.switchToScriptingFallback(.readerRefused)
        media.retryNowPlaying(userAsked: false)
        XCTAssertFalse(media.retryingNowPlaying, "a wake must not raise the alert again")
        media.retryNowPlaying(userAsked: true)
        XCTAssertTrue(media.retryingNowPlaying)
        media.stop()
    }

    // MARK: - A helper that speaks but says nothing (G-009)

    /// One torn line is not a dead helper, but five in a row is a helper
    /// whose every record is garbage, and it used to count as healthy: any
    /// byte refreshed the silence watchdog and an undecodable line was
    /// dropped without a word.
    func testFiveGarbledLinesInARowRestartTheHelper() {
        var watch = UndecodableLineWatch()
        for _ in 0..<4 { XCTAssertEqual(watch.record(decoded: false), .keep) }
        XCTAssertEqual(watch.record(decoded: false), .restart, "the fifth in a row")

        var torn = UndecodableLineWatch()
        for _ in 0..<4 { _ = torn.record(decoded: false) }
        XCTAssertEqual(torn.record(decoded: true), .keep)
        for _ in 0..<4 {
            XCTAssertEqual(torn.record(decoded: false), .keep, "a good line starts the count again")
        }
    }

    /// A controller on the helper route, cut off from every real player, with
    /// Spotify running as pid 77 and no player that may be asked.
    private func helperRoute(clock: @escaping () -> TimeInterval) -> MediaController {
        let media = MediaController()
        media.isolateFromPlayers()
        media.automationConsent = { _ in .notAsked }
        media.musicOnly = { false }
        media.lyricsShown = { false }
        media.bundleIdentifierForPID = { $0 == 77 ? PlayerApp.spotify.bundleID : nil }
        media.pidForPlayer = { $0 == .spotify ? 77 : nil }
        media.isProcessRunning = { _ in true }
        media.monotonicNow = clock
        return media
    }

    private let playingSpotify: [AnyHashable: Any] = [
        "Name": "A", "Artist": "B", "Album": "C",
        "Duration": 200000, "Player State": "Playing", "Playback Position": 1.0,
    ]

    private var emptyRecord: NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.takenAt = Date()
        return snapshot
    }

    /// What a MediaRemote closed to perl looks like: the helper stays up and
    /// publishes records with every field blank. The island said "Nothing is
    /// playing" over a playing Spotify, and Settings showed no problem.
    func testAnEmptyFeedUnderAPlayingSpotifyFallsBack() {
        var now: TimeInterval = 1_000
        let media = helperRoute { now }
        media.hearAnnouncement(from: .spotify, playingSpotify)
        media.playerAnnouncedChange(.spotify)
        for second in stride(from: 0.0, through: 12, by: 2) {
            now = 1_000 + second
            media.feedDelivered(emptyRecord)
        }
        XCTAssertEqual(media.fallbackReason?.rawValue, "reportsNothing")
        XCTAssertEqual(media.track?.title, "A", "the fallback shows Spotify from its own announcement")
        media.stop()
    }

    /// An idle Mac publishes nothing but empty records, and that is the truth.
    /// Without a player saying it plays, emptiness is never a failure.
    func testAnEmptyFeedWithNothingPlayingStaysOnTheHelper() {
        var now: TimeInterval = 1_000
        let media = helperRoute { now }
        media.hearAnnouncement(from: .spotify, [
            "Name": "A", "Artist": "B", "Album": "C", "Duration": 200000, "Player State": "Paused",
        ])
        for second in stride(from: 0.0, through: 60, by: 2) {
            now = 1_000 + second
            media.feedDelivered(emptyRecord)
        }
        XCTAssertNil(media.fallbackReason)
        media.stop()
    }

    /// A real record after the announcement proves the route: a song that
    /// stops later is just a song that stopped.
    func testARealRecordAfterTheAnnouncementKeepsTheHelper() {
        var now: TimeInterval = 1_000
        let media = helperRoute { now }
        media.hearAnnouncement(from: .spotify, playingSpotify)
        var real = emptyRecord
        real.title = "A"
        real.artist = "B"
        real.album = "C"
        real.isPlaying = true
        real.rate = 1
        real.duration = 200
        real.playerPID = 77
        now = 1_001
        media.feedDelivered(real)
        for second in stride(from: 2.0, through: 30, by: 2) {
            now = 1_000 + second
            media.feedDelivered(emptyRecord)
        }
        XCTAssertNil(media.fallbackReason)
        media.stop()
    }

    /// A controller on the fallback, showing whatever the announcements say.
    private func onFallback() -> MediaController {
        let media = helperRoute { 1_000 }
        media.switchToScriptingFallback(.keptStopping)
        return media
    }

    /// A wake retry gave the working fallback up on the helper's first
    /// record, even an empty one from a MediaRemote still waking, and that
    /// cleared the island over a song that was playing.
    func testARetryKeepsTheFallbackOnAnEmptyRecordWhileItShowsASong() {
        let media = onFallback()
        media.fallbackHeard(.spotify, playingSpotify)
        XCTAssertEqual(media.track?.title, "A")

        media.retryNowPlaying(userAsked: true)
        media.feedDelivered(emptyRecord)
        XCTAssertNotNil(media.fallbackReason, "an empty record proves nothing while the fallback shows a song")
        XCTAssertEqual(media.track?.title, "A")
        XCTAssertTrue(media.retryingNowPlaying, "the first real record still hands over")

        var real = emptyRecord
        real.title = "A"
        real.artist = "B"
        real.album = "C"
        real.isPlaying = true
        real.rate = 1
        real.duration = 200
        real.playerPID = 77
        media.feedDelivered(real)
        XCTAssertNil(media.fallbackReason)
        XCTAssertFalse(media.retryingNowPlaying)
        media.stop()
    }

    /// With nothing on the fallback either, an empty record is agreement, so
    /// Try Again still clears the reason on an idle Mac.
    func testARetryHandsOverOnAnEmptyRecordWhenTheFallbackShowsNothing() {
        let media = onFallback()
        XCTAssertNil(media.track)
        media.retryNowPlaying(userAsked: true)
        media.feedDelivered(emptyRecord)
        XCTAssertNil(media.fallbackReason)
        XCTAssertFalse(media.retryingNowPlaying)
        media.stop()
    }

    // MARK: - The restart budget (K-013)

    /// One player's metadata killing the helper ten seconds after each start
    /// used to be relaunched forever: the budget was forgiven 300 s after the
    /// first failure, and a ten-second life with the backoff's delays spans
    /// more than that before the ninth failure. About 2,000 perl launches a
    /// day, a stale island for up to a minute each time, and no word.
    func testAHelperThatDiesEveryTenSecondsFallsBack() {
        var policy = NowPlayingFailurePolicy()
        var now: TimeInterval = 10_000
        var action = NowPlayingFailurePolicy.Action.restart(after: 0)
        for _ in 0..<12 {
            policy.recordLaunch(now: now)
            policy.recordSuccess()
            now += 10
            action = policy.recordFailure(now: now)
            guard case .restart(let delay) = action else { break }
            now += delay
        }
        XCTAssertEqual(action, .fallback)
    }

    /// A helper that ran five minutes and then died is a fresh failure, not
    /// one more in a bad streak.
    func testAHelperThatSurvivedFiveMinutesIsForgiven() {
        var policy = NowPlayingFailurePolicy()
        var now: TimeInterval = 10_000
        for _ in 0..<7 {
            policy.recordLaunch(now: now)
            policy.recordSuccess()
            now += 1
            guard case .restart(let delay) = policy.recordFailure(now: now) else {
                return XCTFail("seven quick deaths are inside the budget")
            }
            now += delay
        }
        policy.recordLaunch(now: now)
        now += 300
        XCTAssertEqual(policy.recordFailure(now: now), .restart(after: 2))
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

import XCTest
@testable import IslaKit

final class NowPlayingCommandTests: XCTestCase {
    func testCommandsUsePerClientMediaRemoteCodes() {
        XCTAssertEqual(NowPlayingFeed.Command.play.rawValue, 0)
        XCTAssertEqual(NowPlayingFeed.Command.pause.rawValue, 1)
        XCTAssertEqual(NowPlayingFeed.Command.next.rawValue, 4)
        XCTAssertEqual(NowPlayingFeed.Command.previous.rawValue, 5)
    }

    func testCommandLineTargetsThePlayerShownInThePanel() {
        XCTAssertEqual(
            NowPlayingFeed.Command.pause.wireLine(playerPID: 42),
            "cmd 1 42"
        )
    }

    /// A lyric line starting 0.7s into its second is sought to the
    /// millisecond, not floored onto the line before it.
    func testSeekLineCarriesTheFraction() {
        XCTAssertEqual(NowPlayingFeed.seekWireLine(seconds: 105.72, playerPID: 42), "seek 105.720 42")
        XCTAssertEqual(PlayerBridge.Transport.seek(seconds: 105.72).body(for: .spotify), "set player position to 105.720")
    }

    /// A click on a line survives the player landing a little short: the
    /// target sits far enough past the line's start that the line clicked is
    /// still the one lit.
    func testALyricClickSurvivesAShortLanding() {
        let lead = 0.2
        let lineAt = 105.7
        let target = LyricsStage.clickTarget(lineAt: lineAt, lead: lead, duration: 240)
        let landedShort = target - 0.08
        XCTAssertGreaterThanOrEqual(landedShort + lead, lineAt, "still inside the clicked line")
        XCTAssertLessThan(target, lineAt, "and the audio still starts ahead of the voice")
    }

    func testSeekLineTargetsThePlayerShownInThePanel() {
        XCTAssertEqual(
            NowPlayingFeed.seekWireLine(seconds: 30, playerPID: 42),
            "seek 30.000 42"
        )
    }
}

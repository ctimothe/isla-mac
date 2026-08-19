import XCTest
@testable import DynamicIslandKit

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

    func testSeekLineTargetsThePlayerShownInThePanel() {
        XCTAssertEqual(
            NowPlayingFeed.seekWireLine(seconds: 30, playerPID: 42),
            "seek 30 42"
        )
    }
}

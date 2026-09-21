import XCTest
@testable import IslaKit

/// The lookup against the real LRCLIB, for songs that showed "No lyrics found"
/// on the owner's Mac on 2026-09-21. Skipped unless `LRCLIB_LIVE=1`: CI never
/// touches the network, and a public service's contents are not a gate.
final class OnlineLyricsLiveTests: XCTestCase {
    func testSongsTheExactQueryMissedAreFound() async throws {
        guard ProcessInfo.processInfo.environment["LRCLIB_LIVE"] == "1" else {
            throw XCTSkip("set LRCLIB_LIVE=1 to ask the real catalogue")
        }
        let songs: [(String, String, String, TimeInterval)] = [
            ("waltz", "Esha Tewari", "waltz", 164),
            ("We Say Goodbye", "Solya", "We Say Goodbye", 143),
            ("I Bet on Losing Dogs", "Mitski", "Puberty 2", 172),
        ]
        for (title, artist, album, duration) in songs {
            let identity = LocalTrackIdentity(
                playerID: "spotify", title: title, artist: artist, album: album,
                duration: duration, recordingID: nil
            )
            let outcome = await OnlineLyrics.lookUp(identity)
            guard case .found(let timeline) = outcome else {
                XCTFail("\(title): \(outcome)")
                continue
            }
            print("LIVE \(title): \(timeline.lines.count) lines, first \(timeline.lines.first?.text ?? "-")")
        }
    }
}

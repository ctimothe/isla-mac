import XCTest
@testable import IslaKit

/// The album cover has to come back.
@MainActor
final class ArtworkRecoveryTests: XCTestCase {

    /// The reported bug, as a decision table.
    ///
    /// Play something else, come back to Spotify, and the cover was a grey note
    /// for the rest of the song: artwork rides only the update where it changed,
    /// the app's copy had been cleared when the session went empty, and the
    /// helper still held the same artwork id so it never sent one again.
    func testACoverThatWentMissingIsAskedForOnce() {
        XCTAssertTrue(
            MediaController.shouldAskForArtwork(
                showing: false, describesDisplayedTrack: true,
                feedAvailable: true, alreadyAsked: false
            ),
            "displaying a track with no cover is exactly when to ask"
        )
        XCTAssertFalse(
            MediaController.shouldAskForArtwork(
                showing: false, describesDisplayedTrack: true,
                feedAvailable: true, alreadyAsked: true
            ),
            "a session with genuinely no cover must not be asked twice a second forever"
        )
    }

    func testNothingIsAskedForWhenThereIsNothingToFix() {
        // Already showing it.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: true, describesDisplayedTrack: true,
            feedAvailable: true, alreadyAsked: false
        ))
        // The cover we hold belongs to a different track; the track-change path
        // owns that case and blanks it deliberately.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: false, describesDisplayedTrack: false,
            feedAvailable: true, alreadyAsked: false
        ))
        // The scripting fallback is driving. There is no helper listening.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: false, describesDisplayedTrack: true,
            feedAvailable: false, alreadyAsked: false
        ))
    }

    /// The wire word, which the helper matches exactly.
    func testTheHelperIsAskedInAWordItKnows() {
        XCTAssertEqual(NowPlayingFeed.artworkRequestLine, "art")
    }
}

import XCTest
@testable import IslaKit

/// The player's Favourite star (spec §19.6): drawn only when something can
/// act on it — Music through the scripting bridge, or Spotify through a
/// connected account's library — and absent otherwise, never a star that
/// does nothing.
@MainActor
final class PlayerFavouriteTests: XCTestCase {
    typealias Favourite = MediaPane.Favourite

    /// Music answered the favourite question: its star, in the state it said.
    func testMusicAnswersWithItsOwnStar() {
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: true, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]),
            .music(isOn: true)
        )
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: false, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]),
            .music(isOn: false)
        )
    }

    /// Spotify's star needs a connected account that can write the library
    /// and the song's id; the library's answer is its state, and "not yet
    /// answered" draws it off.
    func testSpotifyNeedsAnAccountThatCanSave() {
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: true, saved: ["abc": true]),
            .spotify(trackID: "abc", isOn: true)
        )
        let unanswered = Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: true, saved: [:])
        XCTAssertEqual(unanswered, .spotify(trackID: "abc", isOn: nil))
        XCTAssertEqual(unanswered?.isOn, false)
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: false, saved: ["abc": true]))
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: nil, spotifyCanSave: true, saved: [:]))
    }

    /// A browser, or any player that answers neither, has no star.
    func testNoBridgeNoStar() {
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]))
    }

    /// Music's answer rides on the playback-modes round trip: "true",
    /// "false", or "none" when there was no current track to ask.
    func testTheBridgeReadsMusicsAnswer() {
        XCTAssertEqual(PlayerBridge.favorite("true"), true)
        XCTAssertEqual(PlayerBridge.favorite("false"), false)
        XCTAssertNil(PlayerBridge.favorite("none"))
        XCTAssertNil(PlayerBridge.favorite(""))
    }

    /// The write goes to Music's own property; Spotify's scripting has none,
    /// and its body does nothing.
    func testTheBridgeWritesOnlyMusicsProperty() {
        XCTAssertEqual(
            PlayerBridge.Transport.favorite(true).body(for: .music), "set favorited of current track to true"
        )
        XCTAssertEqual(
            PlayerBridge.Transport.favorite(false).body(for: .music), "set favorited of current track to false"
        )
        XCTAssertEqual(PlayerBridge.Transport.favorite(true).body(for: .spotify), "return")
    }
}

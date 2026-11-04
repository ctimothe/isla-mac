import XCTest
@testable import IslaKit

/// The lock card's Favourite is the player's star (spec §19.6), not a
/// Spotify-only heart: the owner wanted one control for one thing
/// (2026-10-24). Music answers through the scripting bridge, Spotify only for a
/// connected account that is answering, anything else gets no star.
@MainActor
final class LockCardFavouriteTests: XCTestCase {
    private func resolve(
        music: Bool? = nil, track: String? = nil, connected: Bool = false, blocked: Bool = false,
        tokenGone: Bool = false, saved: [String: Bool] = [:]
    ) -> MediaPane.Favourite? {
        LockScreenCard.favourite(
            musicFavorite: music, spotifyTrackID: track, spotifyConnected: connected, apiBlocked: blocked,
            tokenUnavailable: tokenGone, saved: saved
        )
    }

    /// Music's answer is its star whether or not Spotify is connected.
    func testMusicHasAStarWithoutSpotify() {
        XCTAssertEqual(resolve(music: true), .music(isOn: true))
        XCTAssertEqual(resolve(music: false), .music(isOn: false))
        XCTAssertEqual(resolve(music: false, track: "t", connected: true, saved: ["t": true]), .music(isOn: false))
    }

    /// Spotify's is drawn for a connected, answering account and a Spotify song.
    func testSpotifyNeedsAConnectedAnsweringAccount() {
        XCTAssertEqual(
            resolve(track: "t", connected: true, saved: ["t": true]), .spotify(trackID: "t", isOn: true)
        )
        XCTAssertNil(resolve(track: "t", connected: false, saved: ["t": true]), "not connected")
        XCTAssertNil(resolve(track: "t", connected: true, blocked: true), "Spotify refused the account")
        XCTAssertNil(resolve(track: "t", connected: true, tokenGone: true), "the token is gone")
        XCTAssertNil(resolve(track: nil, connected: true), "not a Spotify song")
    }

    /// Anything else has no star: a browser, Yandex Music, Music refusing
    /// Automation.
    func testNothingToFavouriteIsNoStar() {
        XCTAssertNil(resolve())
    }

    /// Until the library has answered the star is dimmed and cannot be pressed.
    func testPendingSpotifyAnswerIsNotPressable() throws {
        let pending = try XCTUnwrap(resolve(track: "t", connected: true))
        XCTAssertFalse(pending.isAnswered)
        XCTAssertFalse(pending.isOn)
        XCTAssertTrue(try XCTUnwrap(resolve(track: "t", connected: true, saved: ["t": false])).isAnswered)
        XCTAssertTrue(MediaPane.Favourite.music(isOn: false).isAnswered)
    }

    /// Spotify's labels stay Spotify's and Music's are the player's.
    func testLabelsFollowTheSource() {
        let label = LockScreenCard.favouriteLabel
        XCTAssertEqual(label(.music(isOn: false)), localized("Favorite"))
        XCTAssertEqual(label(.music(isOn: true)), localized("Remove from Favorites"))
        XCTAssertEqual(label(.spotify(trackID: "t", isOn: false)), localized("Add to Liked Songs"))
        XCTAssertEqual(label(.spotify(trackID: "t", isOn: nil)), localized("Add to Liked Songs"))
        XCTAssertEqual(label(.spotify(trackID: "t", isOn: true)), localized("Remove from Liked Songs"))
    }
}

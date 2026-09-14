import AppKit
import XCTest
@testable import IslaKit

/// The badge on the cover names the app the sound is coming from.
@MainActor
final class SourceIconTests: XCTestCase {

    private func snapshot(pid: pid_t, source: String) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = "Track"
        s.artist = "Artist"
        s.album = ""
        s.duration = 200
        s.elapsed = 10
        s.rate = 1
        s.isPlaying = true
        s.takenAt = Date()
        s.playerPID = pid
        s.source = source
        return s
    }

    /// Resolved from the running process, so any player gets its own icon
    /// without this app knowing anything about it.
    ///
    /// The comparison is against the same source of truth rather than a literal,
    /// because the test host is a command-line process and `NSRunningApplication`
    /// gives it no icon — asserting non-nil here would only be asserting what
    /// kind of process the tests run in. The `XCTSkip` keeps that from reading
    /// as a pass.
    func testTheIconComesFromTheRunningPlayer() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let expected = NSRunningApplication(processIdentifier: me)?.icon
        try XCTSkipIf(expected == nil, "this test host has no application icon to resolve")

        let media = MediaController()
        media.apply(snapshot(pid: me, source: "Test Player"))
        XCTAssertEqual(media.sourceName, "Test Player")
        // Not `XCTAssertEqual` against the icon itself: `NSImage` compares by
        // identity, and `NSRunningApplication` hands back a fresh instance each
        // time it is asked — so equality here fails for two images of the same
        // icon, which says nothing about the badge.
        XCTAssertNotNil(media.sourceIcon, "the badge should carry the player's own icon")
        XCTAssertEqual(media.sourceIcon?.size, expected?.size)
    }

    /// A pid nothing is running under has no icon, and the card falls back to
    /// the first letter rather than drawing an empty circle.
    func testAnUnknownPlayerHasNoIcon() {
        let media = MediaController()
        // Well past the pid range in use, so nothing can be running under it.
        media.apply(snapshot(pid: 999_999, source: "Ghost"))
        XCTAssertNil(media.sourceIcon)
        XCTAssertEqual(media.sourceName, "Ghost")
    }

    /// Losing the session clears the badge with everything else, so one
    /// player's icon can never sit on another player's track.
    func testTheIconGoesWithTheSession() {
        let media = MediaController()
        media.apply(snapshot(pid: ProcessInfo.processInfo.processIdentifier, source: "Test Player"))
        XCTAssertEqual(media.sourceName, "Test Player")

        media.apply(NowPlayingFeed.Snapshot())
        XCTAssertNil(media.sourceIcon)
        XCTAssertNil(media.sourceName)
    }

    /// The lookup is cached per pid, so it must be re-run when the player
    /// changes — otherwise one app's icon outlives its session.
    func testTheIconIsResolvedAgainWhenThePlayerChanges() {
        let media = MediaController()
        media.foreignHoldWindow = 0
        media.apply(snapshot(pid: ProcessInfo.processInfo.processIdentifier, source: "First"))

        var second = snapshot(pid: 999_998, source: "Second")
        second.title = "Another"
        media.apply(second)
        media.apply(second)

        XCTAssertNil(media.sourceIcon, "nothing runs under that pid, so the old icon must not persist")
    }
}

import AppKit
import Combine
import XCTest
@testable import IslaKit

/// One swap per song (redesign spec §19.6, amendment 2026-10-25).
///
/// Owner, 2026-10-25, after a skip: "the contents are loading and they are not
/// even consistent — they should load at once". The island, the player, the
/// stage and the lock card drew the new title over the old cover, then over
/// the placeholder, then the new cover, the tint a step after that and the
/// artist jumping rows twice. These hold the presenter that replaces it: the
/// old song stays drawn, still, until the new one's title and cover can be
/// swapped in together — 350 ms from the new title at most, 700 ms from the
/// hold's start at the very most.
@MainActor
final class NowPlayingPresenterTests: XCTestCase {
    // MARK: Rig

    /// A clock that moves only when told, and the wakes armed against it.
    @MainActor
    private final class ManualTime {
        var now: TimeInterval = 100
        private var wakes: [(at: TimeInterval, action: @MainActor @Sendable () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            wakes.append((now + delay, action))
        }

        /// Moves the clock to `seconds` after the start and fires every wake
        /// that has come due, in order.
        func advance(by seconds: TimeInterval) {
            now += seconds
            while let index = wakes.indices.filter({ wakes[$0].at <= now + 1e-9 })
                .min(by: { wakes[$0].at < wakes[$1].at }) {
                let wake = wakes.remove(at: index)
                wake.action()
            }
        }
    }

    @MainActor
    private final class Rig {
        let time = ManualTime()
        var lyricsReady = false
        var lyricHolds: [Bool] = []
        var position: TimeInterval = 42
        var changes: [NowPlayingPresenter.Presented?] = []
        var cancellables = Set<AnyCancellable>()
        var presenter: NowPlayingPresenter!
    }

    private func rig(tintKnown: @escaping (NSImage) -> CoverTint? = { _ in .fallback }) -> Rig {
        let rig = Rig()
        rig.presenter = NowPlayingPresenter(
            now: { [time = rig.time] in time.now },
            schedule: { [time = rig.time] delay, wake in time.schedule(delay, wake) },
            clock: { [weak rig] in NowPlayingPresenter.HeldClock(position: rig?.position ?? 0, isPlaying: true) },
            cachedTint: { image in image.map(tintKnown) ?? .fallback },
            resolveTint: { _ in .fallback },
            lyricsReady: { [weak rig] in rig?.lyricsReady ?? false },
            holdLyrics: { [weak rig] holding in rig?.lyricHolds.append(holding) }
        )
        rig.presenter.$presented.dropFirst()
            .sink { [weak rig] in rig?.changes.append($0) }
            .store(in: &rig.cancellables)
        return rig
    }

    private func track(_ title: String, album: String = "Album") -> MediaController.Track {
        MediaController.Track(title: title, artist: "Artist", album: album, key: "1|\(title)|Artist|\(album)")
    }

    private func cover() -> NSImage { NSImage(size: NSSize(width: 4, height: 4)) }

    /// A reading of `track`, with `artwork` owned by `coverFor` (the song
    /// itself unless said otherwise).
    private func reading(
        _ track: MediaController.Track?, artwork: NSImage? = nil, coverFor: MediaController.Track? = nil,
        duration: TimeInterval = 200
    ) -> MediaController.Reading {
        MediaController.Reading(
            track: track, duration: duration, artwork: artwork,
            coverKey: artwork == nil ? nil : (coverFor ?? track)?.key, sourceIcon: nil
        )
    }

    /// Song A on screen with its cover, the change counter reset.
    private func playingA(_ rig: Rig) -> (MediaController.Track, NSImage) {
        let a = track("A")
        let coverA = cover()
        rig.presenter.receive(reading(a, artwork: coverA))
        XCTAssertEqual(rig.presenter.presented?.track, a, "the fixture: the first song is drawn at once")
        rig.changes = []
        return (a, coverA)
    }

    /// What `skip` does in the app: the controller about to name `next`, then
    /// its reading.
    private func report(_ rig: Rig, _ next: MediaController.Track, artwork: NSImage? = nil,
                        coverFor: MediaController.Track? = nil) {
        rig.presenter.trackWillChange(to: next.key)
        rig.presenter.receive(reading(next, artwork: artwork, coverFor: coverFor))
    }

    // MARK: One swap

    /// Title, then cover inside the deadline: one published change, carrying
    /// both. The old song stays drawn, its clock still, until then.
    func testTitleThenCoverWithinTheDeadlineIsOneChange() {
        let rig = rig()
        let (a, coverA) = playingA(rig)
        let b = track("B", album: "Other")
        let coverB = cover()

        report(rig, b, artwork: coverA, coverFor: a)          // the old picture still up
        XCTAssertEqual(rig.presenter.presented?.track, a, "the old song stays while the new one loads")
        XCTAssertEqual(rig.presenter.held?.position, 42, "with its clock still")

        rig.time.advance(by: 0.07)
        rig.presenter.receive(reading(b))                     // the old cover taken down
        rig.time.advance(by: 0.05)
        rig.presenter.receive(reading(b, artwork: coverB))    // the new one in

        XCTAssertEqual(rig.changes.count, 1, "one swap, not a field at a time")
        XCTAssertEqual(rig.presenter.presented?.track, b)
        XCTAssertTrue(rig.presenter.presented?.artwork === coverB, "title and cover together")
        XCTAssertNil(rig.presenter.held, "the clock runs again")

        rig.time.advance(by: 1)
        XCTAssertEqual(rig.changes.count, 1, "and nothing after it")
    }

    /// No cover by the deadline: the song swaps in with the placeholder at
    /// 350 ms, and the cover fills in later under the same key.
    func testWithNoCoverTheSongSwapsAtTheDeadlineAndTheCoverFillsIn() {
        let rig = rig()
        _ = playingA(rig)
        let b = track("B", album: "Other")

        report(rig, b)
        rig.time.advance(by: 0.34)
        XCTAssertEqual(rig.presenter.presented?.track.title, "A", "still waiting for the cover")
        rig.time.advance(by: 0.01)
        XCTAssertEqual(rig.presenter.presented?.track, b, "swapped at 350 ms")
        XCTAssertNil(rig.presenter.presented?.artwork, "with the placeholder, never the old cover")
        XCTAssertEqual(NowPlayingPresenter.swapDeadline, 0.35)

        let coverB = cover()
        rig.time.advance(by: 0.4)
        rig.presenter.receive(reading(b, artwork: coverB))
        XCTAssertEqual(rig.changes.count, 2, "the swap, then the cover filling in")
        XCTAssertEqual(rig.presenter.presented?.key, b.key, "under the same key")
        XCTAssertTrue(rig.presenter.presented?.artwork === coverB)
    }

    /// The cover's tint is part of the cover: the swap waits for it, so the
    /// equalizer recolours in the swap and not a step after.
    func testTheTintArrivesWithTheCover() async {
        var known: [ObjectIdentifier: CoverTint] = [:]
        let red = CoverTint(red: 0.9, green: 0.2, blue: 0.1)
        let rig = rig(tintKnown: { known[ObjectIdentifier($0)] })
        let coverA = cover()
        known[ObjectIdentifier(coverA)] = .fallback
        let a = track("A")
        rig.presenter.receive(reading(a, artwork: coverA))
        rig.changes = []

        let b = track("B", album: "Other")
        let coverB = cover()
        report(rig, b)
        rig.presenter.receive(reading(b, artwork: coverB))
        XCTAssertEqual(rig.presenter.presented?.track, a, "a cover whose colour is unread is not in yet")

        known[ObjectIdentifier(coverB)] = red
        rig.presenter.receive(reading(b, artwork: coverB))
        XCTAssertEqual(rig.changes.count, 1)
        XCTAssertEqual(rig.presenter.presented?.tint, red, "cover and colour in one change")
    }

    // MARK: A run of skips

    /// A → B → C inside one hold: B is never drawn, and the deadline runs from
    /// C's title.
    func testASkipDuringTheHoldFollowsTheNewestAndNeverShowsTheOneInBetween() {
        let rig = rig()
        _ = playingA(rig)
        let b = track("B", album: "Second")
        let c = track("C", album: "Third")

        report(rig, b)
        rig.time.advance(by: 0.2)
        report(rig, c)
        rig.time.advance(by: 0.34)
        XCTAssertEqual(rig.presenter.presented?.track.title, "A", "C's deadline, not B's")
        rig.time.advance(by: 0.01)
        XCTAssertEqual(rig.presenter.presented?.track, c)
        XCTAssertFalse(rig.changes.contains { $0?.track == b }, "B was never drawn")
        XCTAssertEqual(rig.changes.count, 1)
    }

    /// A report that names another song and then comes back to the one on
    /// screen ends the hold at once: nothing is swapped, the clock runs.
    func testAReportComingBackToTheSongOnScreenEndsTheHold() {
        let rig = rig()
        let (a, coverA) = playingA(rig)
        report(rig, track("B", album: "Other"))
        rig.time.advance(by: 0.1)
        rig.presenter.receive(reading(a, artwork: coverA))
        XCTAssertNil(rig.presenter.held)
        XCTAssertTrue(rig.changes.isEmpty)
    }

    /// However many titles arrive, the hold ends 700 ms after it began.
    func testTheCapHoldsThroughARunOfSkips() {
        let rig = rig()
        _ = playingA(rig)

        report(rig, track("B", album: "Second"))
        rig.time.advance(by: 0.3)
        report(rig, track("C", album: "Third"))
        rig.time.advance(by: 0.3)
        let d = track("D", album: "Fourth")
        report(rig, d)
        rig.time.advance(by: 0.09)
        XCTAssertEqual(rig.presenter.presented?.track.title, "A")
        rig.time.advance(by: 0.01)
        XCTAssertEqual(rig.presenter.presented?.track, d, "swapped at the 700 ms cap, not D's own deadline")
        XCTAssertEqual(NowPlayingPresenter.holdCap, 0.7)
        XCTAssertEqual(rig.changes.count, 1)
    }

    /// Isla's own Next holds at once; if no song follows, the cap gives the
    /// clock back and nothing is swapped.
    func testANextWithNothingAfterItLetsTheClockRunAgain() {
        let rig = rig()
        _ = playingA(rig)
        rig.presenter.expectTrackChange()
        XCTAssertNotNil(rig.presenter.held, "held from the click")
        rig.time.advance(by: 0.7)
        XCTAssertNil(rig.presenter.held)
        XCTAssertTrue(rig.changes.isEmpty)
        XCTAssertEqual(rig.lyricHolds, [true, false])
    }

    // MARK: Lyrics

    /// Lyrics already settled — local, or cached — swap with the song: the
    /// words are held while the old song is up and released in the swap.
    func testSettledLyricsSwapWithTheSong() {
        let rig = rig()
        _ = playingA(rig)
        let b = track("B", album: "Other")
        report(rig, b)
        XCTAssertEqual(rig.lyricHolds, [true], "the old song's words stay with it")
        rig.lyricsReady = true                               // a local file, found at once
        rig.presenter.receive(reading(b, artwork: cover()))
        XCTAssertEqual(rig.lyricHolds, [true, false], "released in the swap")
        XCTAssertEqual(rig.presenter.presented?.lyricsCameLate, false)
        rig.presenter.lyricsChanged(ready: true)
        XCTAssertEqual(rig.presenter.presented?.lyricsCameLate, false)
    }

    /// Slow online lyrics come after the swap, and only the subtitle turns
    /// for them (`lyricsCameLate`).
    func testSlowLyricsComeAfterTheSwap() {
        let rig = rig()
        _ = playingA(rig)
        let b = track("B", album: "Other")
        report(rig, b)
        rig.presenter.receive(reading(b, artwork: cover()))
        XCTAssertEqual(rig.presenter.presented?.track, b, "the song does not wait for the catalogue")
        XCTAssertEqual(rig.presenter.presented?.lyricsCameLate, false)

        rig.time.advance(by: 0.4)
        rig.presenter.lyricsChanged(ready: true)
        XCTAssertEqual(rig.presenter.presented?.lyricsCameLate, true)
        XCTAssertEqual(rig.presenter.presented?.key, b.key)
    }

    // MARK: No hold

    /// The first song, a restart and nothing playing are drawn at once.
    func testTheFirstSongARestartAndClearSwapImmediately() {
        let rig = rig()
        let a = track("A")
        rig.presenter.receive(reading(a))
        XCTAssertEqual(rig.presenter.presented?.track, a, "the first song at once, cover or not")
        XCTAssertNil(rig.presenter.held)

        // A restart is the same song at its start: no new key, no hold.
        rig.presenter.trackWillChange(to: a.key)
        rig.presenter.receive(reading(a, duration: 200))
        XCTAssertNil(rig.presenter.held)
        XCTAssertTrue(rig.lyricHolds.isEmpty)

        // Nothing playing, even mid-hold, is said at once.
        rig.presenter.trackWillChange(to: track("B", album: "Other").key)
        XCTAssertNotNil(rig.presenter.held)
        rig.presenter.receive(reading(nil))
        XCTAssertNil(rig.presenter.presented)
        XCTAssertNil(rig.presenter.held)
        XCTAssertEqual(rig.lyricHolds, [true, false])

        // And the next song after nothing is a first song again.
        let c = track("C")
        rig.presenter.receive(reading(c))
        XCTAssertEqual(rig.presenter.presented?.track, c)
    }

    /// The next song on the same album keeps the cover on screen, so it swaps
    /// at once with that cover rather than waiting for its own.
    func testASameAlbumCoverIsCarried() {
        let rig = rig()
        let (_, coverA) = playingA(rig)
        let b = track("B")                                   // the same album
        report(rig, b, artwork: coverA, coverFor: b)         // carried: owned by B now
        XCTAssertEqual(rig.changes.count, 1)
        XCTAssertEqual(rig.presenter.presented?.track, b)
        XCTAssertTrue(rig.presenter.presented?.artwork === coverA)
    }

    // MARK: The peek

    /// The peek keys on the presented track: once per song, with its cover.
    func testThePeekFiresOncePerPresentedTrackWithItsCover() {
        let rig = rig()
        _ = playingA(rig)
        var peeks: [(title: String, cover: NSImage?)] = []
        // The controller's own pipeline (`NotchController`, sneak peek): the
        // presented key, deduplicated, after the first.
        rig.presenter.$presented.removeDuplicates { $0?.key == $1?.key }.dropFirst()
            .sink { presented in
                if let presented { peeks.append((presented.track.title, presented.artwork)) }
            }
            .store(in: &rig.cancellables)

        let b = track("B", album: "Other")
        let coverB = cover()
        report(rig, b)
        rig.presenter.receive(reading(b))
        rig.time.advance(by: 0.05)
        rig.presenter.receive(reading(b, artwork: coverB))
        rig.presenter.receive(reading(b, artwork: coverB, duration: 201))

        XCTAssertEqual(peeks.map(\.title), ["B"], "once for the song, not per report")
        XCTAssertTrue(peeks.first?.cover === coverB, "and with its cover")
    }

    // MARK: Through the controller

    /// The real controller and the live wiring: a skip whose cover follows
    /// its title lands as one change, and the store's words wait for it.
    func testASkipThroughTheControllerIsOneSwap() async throws {
        let media = MediaController()
        media.isolateFromPlayers()
        let store = LyricsStore(offsetsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let presenter = NowPlayingPresenter.live(media: media, lyrics: store)
        var changes: [NowPlayingPresenter.Presented?] = []
        let watch = presenter.$presented.dropFirst().sink { changes.append($0) }
        defer { watch.cancel() }

        media.apply(snapshot("One", album: "First", elapsed: 30, artwork: png(red: true)))
        for _ in 0..<100 where presenter.presented?.artwork == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(presenter.presented?.artwork, "the fixture: the first song's cover")
        changes = []

        media.apply(snapshot("Two", album: "Second", elapsed: 0.1))
        XCTAssertEqual(presenter.presented?.track.title, "One", "the old song stays up")
        XCTAssertTrue(store.holdsPresentation, "and its words with it")
        media.apply(snapshot("Two", album: "Second", elapsed: 0.15, artwork: png(red: false)))
        for _ in 0..<100 where presenter.presented?.track.title != "Two" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(changes.count, 1, "one swap")
        XCTAssertEqual(presenter.presented?.track.title, "Two")
        XCTAssertNotNil(presenter.presented?.artwork, "with its own cover")
        XCTAssertFalse(store.holdsPresentation)
    }

    private func snapshot(
        _ title: String, album: String, elapsed: TimeInterval, artwork: Data? = nil
    ) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.album = album
        s.duration = 200
        s.elapsed = elapsed
        s.isPlaying = true
        s.rate = 1
        s.takenAt = Date()
        s.playerPID = 1
        s.artwork = artwork
        return s
    }

    private func png(red: Bool) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let color = red ? NSColor.red : NSColor.blue
        for x in 0..<4 { for y in 0..<4 { rep.setColor(color, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }
}

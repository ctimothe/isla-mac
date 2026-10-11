import AppKit
import XCTest
@testable import IslaKit

/// Where the lock card's own window goes.
///
/// It used to be the notch panel grown to the size of the display, with the
/// card centred inside it by SwiftUI — which meant every lock resized a live
/// window across the moment the shield goes up, and a resize the window server
/// deferred left the card drawn at a fraction of its size, off to one side. The
/// window is the card now, so its placement is one piece of arithmetic with
/// nothing to defer.
@MainActor
final class LockCardWindowTests: XCTestCase {
    func testTheCardSitsAtTheCentreOfItsDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = LockCardWindow.frame(on: screen, size: LockScreenCard.size)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.midY, screen.midY)
        XCTAssertEqual(frame.size, LockScreenCard.size, "the window is exactly the card")
    }

    /// The notch is not always on the display whose origin is zero.
    func testTheCardFollowsTheDisplayItBelongsTo() {
        let secondary = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let frame = LockCardWindow.frame(on: secondary, size: LockScreenCard.size)
        XCTAssertEqual(frame.midX, secondary.midX)
        XCTAssertEqual(frame.midY, secondary.midY)
        XCTAssertTrue(secondary.contains(frame), "the card must land on its own display")
    }

    /// Whole points, so the glass and its 1pt rim land on the pixel grid
    /// instead of straddling it.
    func testThePlacementIsWholePoints() {
        let odd = CGRect(x: 0, y: 0, width: 1511, height: 981)
        let frame = LockCardWindow.frame(on: odd, size: LockScreenCard.size)
        XCTAssertEqual(frame.origin.x, frame.origin.x.rounded())
        XCTAssertEqual(frame.origin.y, frame.origin.y.rounded())
    }

    /// The window is a little bigger than the card, so its edge is never the
    /// thing that clips a rounded corner.
    ///
    /// It was 48pt when the card carried two drop shadows. Cut to exactly the
    /// card, those shadows had nowhere outside to fall and were clipped square
    /// — measured on the running app, the drawn footprint held a constant
    /// 459pt width top to bottom, bottom corners inset 5pt where a 30pt radius
    /// wants about 19. The shadows are gone now, because the system's own lock
    /// player has none; the margin stays small and the corners stay round.
    func testTheWindowLeavesRoomForTheCardsShadow() {
        XCTAssertEqual(
            LockCardWindow.windowSize,
            CGSize(
                width: LockScreenCard.size.width + LockCardWindow.shadowMargin * 2,
                height: LockScreenCard.size.height + LockCardWindow.shadowMargin * 2
            )
        )
        // Small, but never zero: a window flush with the card clips its own
        // rounded edge.
        XCTAssertGreaterThan(LockCardWindow.shadowMargin, 0)
        XCTAssertLessThanOrEqual(
            LockCardWindow.shadowMargin, 16,
            "the drop shadows are gone; this should not creep back up"
        )
    }

    /// And every point of that margin belongs to whatever is underneath, which
    /// while locked is the password field.
    func testTheTransparentMarginTakesNoClicks() {
        let card = CGRect(
            x: LockCardWindow.shadowMargin, y: LockCardWindow.shadowMargin,
            width: LockScreenCard.size.width, height: LockScreenCard.size.height
        )
        let root = LockCardRootView(
            frame: CGRect(origin: .zero, size: LockCardWindow.windowSize)
        )
        root.cardRect = card

        XCTAssertNil(root.hitTest(NSPoint(x: 4, y: 4)), "the corner of the margin")
        XCTAssertNil(
            root.hitTest(NSPoint(x: card.midX, y: 8)),
            "directly below the card, where the shadow is drawn"
        )
        XCTAssertNotNil(
            root.hitTest(NSPoint(x: card.midX, y: card.midY)),
            "the card itself still answers"
        )
    }

    // MARK: - A lock with nothing playing (F-026)
    //
    // Every lock makes the card's window, whether or not there is anything to
    // put on it. The card draws nothing without a track, but its window used
    // to take clicks across the whole 460x300 card rect at the centre of the
    // display — clicks aimed at the login UI vanished into a transparent
    // window — and it started an AudioWatch whose CoreAudio listeners ran for
    // the whole lock to feed a volume rail nobody could see. The window stays
    // (presenting it mid-lock would race the shield's own ordering, the bug
    // that gave the card its own window); it is inert until there is a track.

    private static var cardRect: CGRect {
        CGRect(
            x: LockCardWindow.shadowMargin, y: LockCardWindow.shadowMargin,
            width: LockScreenCard.size.width, height: LockScreenCard.size.height
        )
    }

    /// An empty card's rect belongs to whatever is underneath, the same as the
    /// margin around it.
    func testAnEmptyCardTakesNoClicks() {
        let root = LockCardRootView(
            frame: CGRect(origin: .zero, size: LockCardWindow.windowSize)
        )
        root.cardRect = Self.cardRect
        root.isInteractive = { false }

        XCTAssertNil(
            root.hitTest(NSPoint(x: Self.cardRect.midX, y: Self.cardRect.midY)),
            "a card that draws nothing must not swallow a click on the login window"
        )
    }

    func testTheAudioWatchFollowsTheTrack() {
        XCTAssertFalse(LockCardWindow.watchShouldRun(hasTrack: false))
        XCTAssertTrue(LockCardWindow.watchShouldRun(hasTrack: true))
    }

    /// Inverted from "the card is presented only with a track": the window is
    /// there on every lock, and it is the media controller's track — read at
    /// the moment of the click, not at present — that decides whether it
    /// answers. A song started while locked makes it answer without a second
    /// presentation; the song going away makes it inert again.
    func testAnEmptyLockKeepsAnInertCardThatWakesWithATrack() {
        let media = MediaController()
        let root = LockCardRootView(
            frame: CGRect(origin: .zero, size: LockCardWindow.windowSize)
        )
        root.cardRect = Self.cardRect
        root.isInteractive = LockCardWindow.interactive(following: media)
        let centre = NSPoint(x: Self.cardRect.midX, y: Self.cardRect.midY)

        XCTAssertNil(root.hitTest(centre), "nothing playing: the card takes no clicks")

        media.apply(Self.playing())
        XCTAssertNotNil(root.hitTest(centre), "a track arrived mid-lock: the card answers")

        media.apply(NowPlayingFeed.Snapshot())
        XCTAssertNil(root.hitTest(centre), "the track went away: inert again")
    }

    /// The listeners are installed when a track arrives and removed when it
    /// goes, and an empty lock never installs them at all.
    func testTheWatchStartsAndStopsWithTheTrack() {
        let media = MediaController()
        var installs = 0
        var removals = 0
        let watch = AudioWatch(
            read: { ([], nil, nil) },
            installListeners: { installs += 1 },
            removeListeners: { removals += 1 }
        )
        let following = LockCardWindow.watch(watch, following: media)
        defer { following.cancel() }

        XCTAssertEqual(installs, 0, "an empty lock listens to no audio devices")

        media.apply(Self.playing())
        XCTAssertEqual(installs, 1, "a track arrived: the volume rail needs the machine")
        XCTAssertEqual(removals, 0)

        // A second snapshot of the same song is not a new reason to listen.
        var later = Self.playing()
        later.elapsed = 20
        media.apply(later)
        XCTAssertEqual(installs, 1)

        media.apply(NowPlayingFeed.Snapshot())
        XCTAssertEqual(removals, 1, "the track went away: so do the listeners")

        following.cancel()
        media.apply(Self.playing())
        XCTAssertEqual(installs, 1, "a cancelled subscription starts nothing after dismiss")
    }

    private static func playing() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        return snapshot
    }
}

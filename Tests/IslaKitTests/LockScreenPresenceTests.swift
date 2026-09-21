import XCTest
@testable import IslaKit

@MainActor
final class LockScreenPresenceTests: XCTestCase {
    /// loginwindow can post the lock notification more than once per locked
    /// stretch — the shield redisplays when the display wakes while still
    /// locked — and each side of the transition must fire its work exactly
    /// once per edge, or the panel would fold and re-front on every repeat.
    /// An unlock with no lock before it (launching on an unlocked Mac) must
    /// do nothing at all.
    func testLockUnlockTransitionsFireOnceEach() {
        let presence = LockScreenPresence()
        var locks = 0
        var unlocks = 0
        presence.onLock = { locks += 1 }
        presence.onUnlock = { unlocks += 1 }

        presence.handleUnlock()
        XCTAssertEqual(unlocks, 0)
        XCTAssertFalse(presence.isLocked)

        presence.handleLock()
        presence.handleLock()
        XCTAssertEqual(locks, 1)
        XCTAssertTrue(presence.isLocked)

        presence.handleUnlock()
        presence.handleUnlock()
        XCTAssertEqual(unlocks, 1)
        XCTAssertFalse(presence.isLocked)
    }

    /// The names are the contract with loginwindow: undocumented, but stable
    /// for years and load-bearing in every shipping notch app. A typo here
    /// fails silently — no error, just a pill that never appears — so the
    /// exact strings are pinned.
    func testNotificationNamesAreTheOnesLoginwindowPosts() {
        XCTAssertEqual(LockScreenPresence.lockNotification.rawValue, "com.apple.screenIsLocked")
        XCTAssertEqual(LockScreenPresence.unlockNotification.rawValue, "com.apple.screenIsUnlocked")
    }
}

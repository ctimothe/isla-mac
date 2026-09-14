import AppKit
import XCTest
@testable import IslaKit

@MainActor
final class LockScreenPresenceTests: XCTestCase {
    /// The locked panel must clear the shield, and by the smallest possible
    /// margin: one level, the same distance the panel keeps from the status
    /// window in normal life.
    func testLockedLevelClearsTheShieldByExactlyOne() {
        XCTAssertEqual(LockScreenPresence.lockedLevel(base: 26, shield: 2030), 2031)
    }

    /// A shield reported below the panel's own resting level must not read as
    /// an instruction to sink the panel: locking may raise it, never lower it.
    func testLockedLevelNeverDropsBelowTheNormalLevel() {
        XCTAssertEqual(LockScreenPresence.lockedLevel(base: 26, shield: 3), 26)
    }

    /// The same arithmetic fed the real constants: above the real shield, and
    /// above where the panel normally sits, on the machine the tests run on.
    func testLockedLevelSitsAboveTheRealShieldAndTheNormalLevel() {
        let base = NotchPanel.normalLevel.rawValue
        let shield = Int(CGShieldingWindowLevel())
        let locked = LockScreenPresence.lockedLevel(base: base, shield: shield)
        XCTAssertGreaterThan(locked, shield)
        XCTAssertGreaterThan(locked, base)
    }

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

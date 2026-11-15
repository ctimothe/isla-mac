import Foundation
import XCTest
@testable import IslaKit

/// A test process's stores write to a suite of its own, never to the
/// standard defaults (2026-11-05).
///
/// The standard defaults of a test process are the `com.apple.dt.xctest.tool`
/// domain, shared by every run on the Mac and kept between them. Every
/// `NotchStores()` a test built wrote the lyric store's sign version there, every
/// `PrivacyMode()` its known sections, the rigs their Lyric Delay and the
/// shelf its lists, so a gate run left the domain changed and the next run's
/// stores started from those values (`UserDefaults.stores`).
///
/// Each test takes the key it watches out of the standard defaults first and
/// puts back what was there, so a store writing the value already left by an
/// older run would still show.
@MainActor
final class StoreDefaultsTests: XCTestCase {
    func testATestProcessHasItsOwnSuite() {
        XCTAssertFalse(UserDefaults.stores === UserDefaults.standard, "the stores write the shared xctest domain")
        XCTAssertTrue(TestStoreSuite.name.hasPrefix("com.ctimothe.isla.tests."))
    }

    func testTheLyricStoreLeavesTheStandardDefaultsAlone() {
        let keys = [LyricsStore.offsetKey, LyricsStore.offsetSignVersionKey, LyricsStore.wordKaraokeEnabledKey]
        withStandardKeysSetAside(keys) {
            let lyrics = LyricsStore(offsetsDirectory: temporaryDirectory())
            lyrics.userOffset = 1.25
            lyrics.wordKaraokeEnabled = true
            for key in keys {
                XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) was written to the standard defaults")
            }
            XCTAssertEqual(UserDefaults.stores.double(forKey: LyricsStore.offsetKey), 1.25, accuracy: 1e-9)
            XCTAssertEqual(UserDefaults.stores.integer(forKey: LyricsStore.offsetSignVersionKey), LyricsStore.offsetSignVersion)
            UserDefaults.stores.removeObject(forKey: LyricsStore.offsetKey)
            UserDefaults.stores.removeObject(forKey: LyricsStore.wordKaraokeEnabledKey)
        }
    }

    func testPrivacyModeLeavesTheStandardDefaultsAlone() {
        withStandardKeysSetAside(["privacyKnownSections"]) {
            _ = PrivacyMode()
            XCTAssertNil(UserDefaults.standard.object(forKey: "privacyKnownSections"))
            XCTAssertNotNil(UserDefaults.stores.object(forKey: "privacyKnownSections"))
        }
    }

    func testTheShelfLeavesTheStandardDefaultsAlone() throws {
        let keys = ["shelf.urls", "shelf.urls.bookmarks", "shelf.urls.dates", "shelf.urls.placed"]
        try withStandardKeysSetAside(keys) {
            let file = temporaryDirectory().appendingPathComponent("shelved.txt")
            try Data("x".utf8).write(to: file)
            let shelf = ShelfStore()
            _ = shelf.add([file])
            XCTAssertEqual(shelf.items.count, 1, "the rig did not shelve a file")
            shelf.remove(shelf.items[0])
            for key in keys {
                XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) was written to the standard defaults")
            }
        }
    }

    // MARK: Helpers

    /// Runs `body` with `keys` out of the standard defaults, then puts back
    /// whatever was there.
    private func withStandardKeysSetAside<T>(_ keys: [String], _ body: () throws -> T) rethrows -> T {
        let standard = UserDefaults.standard
        let had = keys.map { standard.object(forKey: $0) }
        keys.forEach { standard.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, had) {
                if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
            }
        }
        return try body()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-store-defaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

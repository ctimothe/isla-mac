import Foundation
import XCTest
@testable import DynamicIslandKit

@MainActor
final class PrivacyModeTests: XCTestCase {
    func testRevealIsTemporaryAndCoverChoicePersists() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyMode(defaults: defaults)

        privacy.setCovering(.notes, true)
        privacy.reveal("note-1")
        XCTAssertFalse(privacy.hides(.notes, "note-1"))

        privacy.coverEverything()
        XCTAssertTrue(privacy.hides(.notes, "note-1"))
        XCTAssertTrue(PrivacyMode(defaults: defaults).covers(.notes))
    }
}

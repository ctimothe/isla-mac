import Foundation
import XCTest
@testable import IslaKit

@MainActor
final class PrivacyModeTests: XCTestCase {
    func testRevealIsTemporaryAndCoverChoicePersists() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyMode(defaults: defaults)

        privacy.setCovering(.clipboard, true)
        privacy.reveal("clip-1")
        XCTAssertFalse(privacy.hides(.clipboard, "clip-1"))

        privacy.coverEverything()
        XCTAssertTrue(privacy.hides(.clipboard, "clip-1"))
        XCTAssertTrue(PrivacyMode(defaults: defaults).covers(.clipboard))
    }
}

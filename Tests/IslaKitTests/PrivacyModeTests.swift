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

    /// ⌃⌥⌘T on a pane the user had already uncovered puts a new clipboard
    /// secret into it; the controller conceals the pane first, so the reveal
    /// meant for the old text does not carry over to the new one.
    func testConcealUndoesAReveal() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyMode(defaults: defaults)

        privacy.setCovering(.translate, true)
        privacy.reveal("translate.source")
        privacy.reveal("clip-1")
        XCTAssertFalse(privacy.hides(.translate, "translate.source"))

        privacy.conceal("translate.source")
        XCTAssertTrue(privacy.hides(.translate, "translate.source"))
        // Only that one: a clipboard row the user uncovered stays uncovered.
        XCTAssertFalse(privacy.hides(.clipboard, "clip-1"))
    }
}

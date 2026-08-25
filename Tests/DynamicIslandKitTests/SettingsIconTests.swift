import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class SettingsIconTests: XCTestCase {

    /// Every symbol has to resolve on the platform this ships to.
    ///
    /// A name macOS does not know draws nothing — not a placeholder, nothing —
    /// so a mistyped or newer-than-the-floor symbol leaves a row with a hole
    /// where its icon should be, and the build stays green. The compiler cannot
    /// catch a string; this can.
    func testEverySettingsSymbolResolves() {
        for name in SettingsIcon.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(name) does not resolve on this system — the row would draw no icon at all"
            )
        }
    }

    /// No symbol is listed twice.
    ///
    /// The set is read at a glance, down a single column, and two rows wearing
    /// the same glyph is the mistake that survives review. `clear` is deliberately
    /// listed once and used by both Clear rows: same action, different files, and
    /// they should look identical.
    func testNoSymbolIsListedTwice() {
        var seen: Set<String> = []
        var repeated: [String] = []
        for name in SettingsIcon.all where !seen.insert(name).inserted {
            repeated.append(name)
        }
        XCTAssertEqual(repeated, [], "unintended duplicate icons: \(repeated)")
    }

    /// Decoration is not meaning.
    ///
    /// `sparkles` sat on "Peek at New Tracks" and said only that something
    /// happens there. It is the house style of generated interfaces and the
    /// reason this list exists; it must not come back.
    func testNoDecorativeSymbols() {
        let decorative = ["sparkles", "wand.and.stars", "wand.and.rays", "star.fill", "sparkle"]
        for name in SettingsIcon.all {
            XCTAssertFalse(
                decorative.contains(name),
                "\(name) decorates rather than names what the row does"
            )
        }
    }

    /// A heart means a liked song. It never meant "connect an account", which is
    /// what it sat on.
    func testAccountRowsUseAnAccountSymbol() {
        XCTAssertTrue(SettingsIcon.connectAccount.hasPrefix("person"))
        XCTAssertTrue(SettingsIcon.disconnectAccount.hasPrefix("person"))
        XCTAssertFalse(SettingsIcon.all.contains { $0.contains("heart") })
    }
}

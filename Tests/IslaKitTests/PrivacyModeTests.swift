import Foundation
import SwiftUI
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

    /// With the cover on, the header still read "6" and row 5 still wore a
    /// link glyph, so a screen-share audience learned how many items there
    /// are and which is a URL (H-026). Hidden, the count is gone and every
    /// row wears one neutral glyph; a revealed row shows its real kind.
    func testTheCoverHidesCountAndKind() {
        XCTAssertNil(NotchContentView.clipboardCounter(count: 6, covered: true))
        XCTAssertEqual(NotchContentView.clipboardCounter(count: 6, covered: false), 6)
        XCTAssertNil(NotchContentView.clipboardCounter(count: 0, covered: false))

        let link = ClipItem(payload: .text("https://example.com"), date: .distantPast)
        let text = ClipItem(payload: .text("a note"), date: .distantPast)
        let file = ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/a.txt")), date: .distantPast)
        for item in [link, text, file] {
            XCTAssertEqual(ClipRow.glyph(for: item, hidden: true), "text.alignleft")
        }
        XCTAssertEqual(ClipRow.glyph(for: link, hidden: false), "link")
        XCTAssertEqual(ClipRow.glyph(for: text, hidden: false), "text.alignleft")
        XCTAssertEqual(ClipRow.glyph(for: file, hidden: false), "doc")
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

    /// The Clipboard tab wrapped its list in a 20 Hz `SpoilerClock` whatever
    /// the cover said, so on a default install, where nothing is covered, an
    /// unchanging list redrew twenty times a second (F-016). The clock runs
    /// only while the section covers and at least one row is still hidden:
    /// revealing the last row stops it, covering again starts it.
    func testTheClipboardClockRunsOnlyForACoveredRow() {
        XCTAssertFalse(ClipboardPane.spoilerClockActive(covers: false, hiddenCount: 0))
        XCTAssertFalse(ClipboardPane.spoilerClockActive(covers: true, hiddenCount: 0))
        XCTAssertTrue(ClipboardPane.spoilerClockActive(covers: true, hiddenCount: 3))
    }

    /// Stopped means stopped: an inactive clock's schedule hands the
    /// timeline nothing past the frame it is drawn with, so the view is not
    /// woken again; an active one keeps producing frames.
    func testAnInactiveSpoilerClockSchedulesNoFurtherFrames() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let idle = SpoilerClock<EmptyView>.schedule(active: false)
            .entries(from: start, mode: .normal)
        XCTAssertLessThanOrEqual(Array(idle.prefix(3)).count, 1)
        let running = SpoilerClock<EmptyView>.schedule(active: true)
            .entries(from: start, mode: .normal)
        XCTAssertEqual(Array(running.prefix(3)).count, 3)
    }
}

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

    /// The Prompter section (spec 5.1, 12): a cover row of its own, listed
    /// only while the switch is on. Its text is the script, which is exactly
    /// what somebody sharing a screen does not want to read out.
    func testThePrompterSectionHasACoverRowAndIsListedOnlyWhileOn() {
        XCTAssertTrue(PrivacyMode.Section.allCases.contains(.prompter))
        XCTAssertEqual(PrivacyMode.Section.prompter.rawValue, "prompter")
        XCTAssertFalse(PrivacyMode.Section.prompter.title.isEmpty)
        XCTAssertFalse(PrivacyMode.Section.prompter.settingsTitle.isEmpty)
        XCTAssertNotEqual(PrivacyMode.Section.prompter.settingsTitle, PrivacyMode.Section.prompter.title)
        XCTAssertFalse(PrivacyMode.Section.shown(prompterEnabled: false).contains(.prompter))
        XCTAssertTrue(PrivacyMode.Section.shown(prompterEnabled: true).contains(.prompter))
    }

    /// Somebody who had everything covered before the Prompter existed has
    /// the Prompter covered too the day they turn it on: the list of sections
    /// grows and "everything" stays everything.
    func testCoveringEverythingIncludesThePrompterSection() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clipboard", "translate"], forKey: PrivacyMode.key)
        defaults.set(["clipboard", "translate"], forKey: "privacyKnownSections")
        let privacy = PrivacyMode(defaults: defaults)
        XCTAssertTrue(privacy.covers(.prompter))
    }

    /// Ruling 20.6 #5. The upgrade above held for one launch only: the first
    /// construction wrote the new list of known sections without the stored
    /// choice, so the second read "two covered of three known" and left the
    /// Prompter uncovered from then on.
    func testCoveringEverythingStillIncludesThePrompterOnTheSecondLaunch() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clipboard", "translate"], forKey: PrivacyMode.key)
        defaults.set(["clipboard", "translate"], forKey: "privacyKnownSections")

        XCTAssertTrue(PrivacyMode(defaults: defaults).covers(.prompter), "first launch")
        let second = PrivacyMode(defaults: defaults)
        XCTAssertTrue(second.covers(.prompter), "second launch")
        XCTAssertEqual(second.sections, Set(PrivacyMode.Section.allCases))
        XCTAssertTrue(PrivacyMode(defaults: defaults).covers(.prompter), "and every one after")
    }

    /// A launch writes nothing: with the Prompter's switch off, no default
    /// naming the Prompter section appears because Isla started (spec 4).
    /// Only the user's own choice in Settings writes the list.
    func testALaunchWritesNoDefaults() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = PrivacyMode(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "privacyKnownSections"), "a fresh launch names no section")
        XCTAssertNil(defaults.object(forKey: PrivacyMode.key))

        defaults.set(["clipboard", "translate"], forKey: PrivacyMode.key)
        defaults.set(["clipboard", "translate"], forKey: "privacyKnownSections")
        _ = PrivacyMode(defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: "privacyKnownSections") as? [String], ["clipboard", "translate"])
        XCTAssertEqual(defaults.array(forKey: PrivacyMode.key) as? [String], ["clipboard", "translate"])
    }

    /// The upgrade is not a lock: a Prompter cover the user turns off stays
    /// off on the next launch, because the choice is written with the list of
    /// sections it was made among.
    func testAPrompterCoverTurnedOffByHandStaysOff() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clipboard", "translate"], forKey: PrivacyMode.key)
        defaults.set(["clipboard", "translate"], forKey: "privacyKnownSections")

        let first = PrivacyMode(defaults: defaults)
        first.setCovering(.prompter, false)
        let second = PrivacyMode(defaults: defaults)
        XCTAssertFalse(second.covers(.prompter))
        XCTAssertTrue(second.covers(.clipboard))
        XCTAssertTrue(second.covers(.translate))
    }
}

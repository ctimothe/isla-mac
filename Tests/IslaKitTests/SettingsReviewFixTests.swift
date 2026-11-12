import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What review of release R4's Settings (2026-10-15) found wrong, one test per
/// finding. Every defaults domain here is a private suite.
@MainActor
final class SettingsReviewFixTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "com.ctimothe.isla.settingsreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - Liked Songs shows no guess

    /// The row said "Allowed" before the API had been asked anything, and "Not
    /// allowed" under a footnote that said the same. It is gone; the line under
    /// the Spotify row is the whole answer, and only for a real refusal.
    func testSpotifyHasNoLikedSongsValueRow() {
        var context = SettingsContext()
        context.spotify = SettingsPane.spotifyConnection(connected: true, needsReconnect: false, signIn: nil, apiBlocked: false)
        XCTAssertEqual(SettingsTable.rows(for: .connections, context: context), [.appleMusicConnection, .spotifyConnection])
        XCTAssertFalse(SettingsRowID.allCases.contains { $0.rawValue == "likedSongs" })
        XCTAssertTrue(SettingsRowID.allCases.filter { $0.kind == .value }.map(\.rawValue) == ["automationStatus"],
                      "the one value row that remains is a real reading")
    }

    /// Every refusal that hides the lock-screen heart is explained, the generic
    /// one included, and nothing is said before a refusal has happened.
    func testEveryRefusalThatHidesTheHeartIsExplained() {
        func line(_ blocked: Bool, _ refusal: SpotifyAccount.Refusal?) -> String? {
            SettingsPane.spotifyConnection(
                connected: true, needsReconnect: false, signIn: nil, apiBlocked: blocked, refusal: refusal
            ).problem
        }
        for refusal in [SpotifyAccount.Refusal.notRegistered, .premiumRequired, .other(nil), .other("Nope")] {
            XCTAssertEqual(line(true, refusal), refusal.explanation, "\(refusal)")
            XCTAssertNil(line(false, refusal), "no refusal has happened: \(refusal)")
        }
        XCTAssertNil(line(true, nil))
    }

    /// One event, one line: a failed sign-in replaces the reconnect note
    /// rather than stacking under it, and a problem on this Mac comes first.
    func testTheSpotifyRowSaysOneThingAtATime() {
        let failure = SpotifyAccount.SignInFailure(stage: .exchange, status: 400, error: "invalid_grant", detail: "Bad code")
        let failed = SettingsPane.spotifyConnection(
            connected: false, needsReconnect: true, signIn: .failed(failure), apiBlocked: false
        )
        XCTAssertEqual(failed.problem, failure.explanation)
        XCTAssertFalse(failed.connected)

        let both = SettingsPane.spotifyConnection(
            connected: false, needsReconnect: true, signIn: .failed(failure), apiBlocked: false,
            problem: .browserDidNotOpen
        )
        XCTAssertEqual(both.problem, SpotifyAccount.SignInProblem.browserDidNotOpen.explanation)

        let revoked = SettingsPane.spotifyConnection(connected: false, needsReconnect: true, signIn: nil, apiBlocked: false)
        XCTAssertEqual(revoked.problem, localized("Spotify ended Isla’s access. Connect again."))

        let cancelled = SettingsPane.spotifyConnection(connected: false, needsReconnect: false, signIn: .cancelled, apiBlocked: false)
        XCTAssertEqual(cancelled.problem, localized("Spotify sign-in was cancelled."))

        let fine = SettingsPane.spotifyConnection(connected: true, needsReconnect: false, signIn: nil, apiBlocked: false)
        XCTAssertNil(fine.problem, "a working account says nothing but Connected")

        let unsaved = SettingsPane.spotifyConnection(
            connected: true, needsReconnect: false, signIn: nil, apiBlocked: false, storage: .unavailable
        )
        XCTAssertEqual(unsaved.problem, localized("Cannot be stored on this Mac."))
    }

    // MARK: - Renamed keys are written back

    func testAWriteOfARenamedKeyAlsoWritesTheLegacyKey() {
        let defaults = suite()
        SettingsRowID.charging.write(false, in: defaults)
        SettingsRowID.headphones.write(false, in: defaults)
        SettingsRowID.newTracks.write(false, in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.chargingKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.legacyShowChargingKey) as? Bool, false,
                       "an older build run afterwards agrees")
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.legacyShowHeadphonesKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.legacySneakPeekKey) as? Bool, false)

        SettingsRowID.charging.write(true, in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.legacyShowChargingKey) as? Bool, true, "and turned back on")
        XCTAssertTrue(NotchViewModel.chargingEnabled(in: defaults))
    }

    func testOtherKeysHaveNoLegacyTwin() {
        let defaults = suite()
        SettingsRowID.keepHistory.write(true, in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.translateKeepHistoryKey) as? Bool, true)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("translate.") || $0.hasPrefix("island.") }.sorted(),
                       [NotchViewModel.translateKeepHistoryKey])
        SettingsRowID.launchAtLogin.write(true, in: defaults)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0 != NotchViewModel.translateKeepHistoryKey && ($0.hasPrefix("translate.") || $0.hasPrefix("island.")) }.isEmpty,
                      "a row with no key writes nothing")
    }

    // MARK: - Acknowledgements always shows something

    func testAcknowledgementsFallsBackToAboutWhenNothingOpens() {
        let url = URL(fileURLWithPath: "/tmp/THIRD_PARTY_NOTICES.md")
        var opened: [URL] = []
        var fell = 0

        // Opens: no fallback.
        SettingsPane.showAcknowledgements(url: url, exists: { _ in true }, open: { opened.append($0); return true }, fallback: { fell += 1 })
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(fell, 0)

        // No handler for Markdown: the open says false.
        SettingsPane.showAcknowledgements(url: url, exists: { _ in true }, open: { _ in false }, fallback: { fell += 1 })
        XCTAssertEqual(fell, 1, "the open was refused")

        // The file is not there: nothing is even tried.
        opened = []
        SettingsPane.showAcknowledgements(url: url, exists: { _ in false }, open: { opened.append($0); return true }, fallback: { fell += 1 })
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(fell, 2, "a missing file")

        // Outside a bundle there is no URL at all.
        SettingsPane.showAcknowledgements(url: nil, exists: { _ in true }, open: { _ in true }, fallback: { fell += 1 })
        XCTAssertEqual(fell, 3)
    }

    // MARK: - The update footnote follows its switch

    func testTheGitHubFootnoteShowsOnlyWhileAutomaticChecksAreOn() {
        let asks = localized("Asks GitHub once an hour for the latest version. It sends nothing about you.")
        XCTAssertEqual(UpdateCheck.automaticInterval, 3600, "the sentence says an hour because the check is hourly")
        LabLocalization.use("ru")
        XCTAssertTrue(
            localized("Asks GitHub once an hour for the latest version. It sends nothing about you.").hasPrefix("Раз в час"), "and in Russian")
        LabLocalization.use("en")
        func footnotes(_ automatic: Bool) -> [String] {
            var context = SettingsContext()
            context.automaticUpdates = automatic
            return SettingsTable.blocks(for: .about, context: context).compactMap { block -> String? in
                if case .footnote(let text) = block { return text } else { return nil }
            }
        }
        XCTAssertTrue(footnotes(true).contains(asks))
        XCTAssertFalse(footnotes(false).contains(asks), "nothing is asked of GitHub while the switch is off")
        XCTAssertFalse(SettingsContext().automaticUpdates, "the switch defaults to off, and so does the line")
    }

    // MARK: - Translate To reads and writes the pane's own defaults

    func testTranslateToReadsTheDefaultsThePaneWasGiven() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.showLyricsKey)
        LyricTranslation.record(target: .german, in: isolated.suite)
        let root = await SettingsFixture.tree(isolated, section: .lyrics)
        XCTAssertTrue(root.dump.contains("German"), "the pop-up shows the suite's choice\n\(root.dump)")
    }

    // MARK: - One reading of the shortcut instruction

    /// The sentence under the three recorders is the instruction, once. A hint
    /// repeating it on each recorder read it four times to VoiceOver.
    func testTheShortcutInstructionIsNotAlsoAHint() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .shortcuts)
        let instruction = localized("Records a new shortcut. Press Delete to clear it, Escape to cancel.")
        XCTAssertNotNil(root.first { $0.value == instruction || $0.label == instruction }, "the footnote stays\n\(root.dump)")
        XCTAssertTrue(root.all { $0.help == instruction }.isEmpty, "no control repeats it\n\(root.dump)")
        for action in [HotKeyAction.openPanel, .showLyrics, .translateClipboard] {
            let recorder = root.first(label: action.title)
            XCTAssertNotNil(recorder, root.dump)
            XCTAssertTrue(recorder?.help.isEmpty ?? true, "\(action.title): \(recorder?.help ?? "")")
        }
    }
}

private extension AXNode {
    func first(where match: (AXNode) -> Bool) -> AXNode? { flattened.first(where: match) }
}

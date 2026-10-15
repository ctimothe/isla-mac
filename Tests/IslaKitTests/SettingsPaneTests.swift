import SwiftUI
import XCTest
@testable import IslaKit

@MainActor
final class SettingsPaneTests: XCTestCase {
    func testNotchStoresOwnOneLocalLibraryForTheSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let stores = NotchStores(localLyricsDirectory: root)

        XCTAssertTrue(stores.localLyricsLibrary === stores.lyricsCoordinator.library)
    }

    func testSettingsCopyPromisesLocalOnlyLyrics() {
        XCTAssertEqual(SettingsPane.localLyricsPrivacyCopyKey, "Lyrics stay on this Mac.")
    }

    /// The cover switches say what they do. Titled only with the tab's name
    /// ("Clipboard", in Russian just "Буфер") and sitting under Clipboard
    /// History, they read as a second way to turn the tab off, and four
    /// personas in the 2026-10-11 audit were afraid to touch them (H-004).
    /// The tab keeps its plain name everywhere else; only Settings names the
    /// cover.
    func testPrivacyCopyNamesWhatItCovers() {
        XCTAssertEqual(PrivacyMode.Section.clipboard.settingsTitle, localized("Cover Clipboard Rows"))
        XCTAssertEqual(PrivacyMode.Section.translate.settingsTitle, localized("Cover Translate Text"))
        XCTAssertEqual(PrivacyMode.Section.clipboard.title, localized("Clipboard"))
        XCTAssertEqual(PrivacyMode.Section.translate.title, localized("Translate"))
        XCTAssertEqual(
            SettingsPane.privacyCoversNote,
            localized("Covered text shows as moving dots until you click it, and is covered again when the panel closes.")
        )
    }

    /// "Copies are not read" was false whenever Save Clipboard Screenshots was
    /// on: that switch keeps the pasteboard poll alive on its own
    /// (`NotchStores.clipboardShouldPoll`), so every copy is still looked at
    /// for an image (J-001). The note follows the switch that decides it.
    func testClipboardOffNoteIsTrueWhenScreenshotsStillPoll() {
        XCTAssertTrue(NotchStores.clipboardShouldPoll(history: false, images: true),
                      "the premise: screenshots alone keep the poll alive")
        XCTAssertEqual(
            SettingsPane.clipboardOffNote(imagesOn: true),
            localized("Copied text is not kept. Copies are still checked for screenshots while Save Clipboard Screenshots is on.")
        )
        XCTAssertFalse(NotchStores.clipboardShouldPoll(history: false, images: false))
        XCTAssertEqual(
            SettingsPane.clipboardOffNote(imagesOn: false),
            localized("Copies are not read or kept. Turning it off emptied the list.")
        )
    }

    /// Hide from Screen Recording is `sharingType = .none` and nothing else,
    /// and whether ScreenCaptureKit honours that on macOS 26 and 27 is not
    /// settled (F-008, live session S7). Until it is, the note under the
    /// switch must not promise more than the mechanism, and must say what to
    /// do instead.
    func testCaptureNoteDoesNotOverpromise() {
        let key = "Asks macOS to leave Isla out of screenshots, recordings and screen sharing. "
            + "Some sharing apps may still show it, so cover Clipboard and Translate before you share."
        XCTAssertEqual(SettingsPane.hideFromCaptureNote, localized(key))
        XCTAssertTrue(key.contains("Some sharing apps"))
        XCTAssertTrue(key.contains("cover Clipboard and Translate"))
    }

    /// Both notes are rows in the Privacy card, not only keys in the strings
    /// file: a constant nobody draws would pass the tests above and change
    /// nothing a user reads.
    func testPrivacyCardShowsBothNotes() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .privacy)
        for text in [SettingsPane.privacyCoversNote, SettingsPane.hideFromCaptureNote] {
            XCTAssertFalse(root.all { $0.label == text || $0.value == text || $0.title == text }.isEmpty,
                           "no note reading \(text)\n\(root.dump)")
        }
    }

    /// Every switch in Settings is the whole row, read the way VoiceOver reads it.
    ///
    /// This replaces a source grep for `.labelsHidden()`, which held the label
    /// and nothing else: the switch it described was AppKit's 36×16 mini switch
    /// with its title detached beside it, so a click on "Launch at Login" — the
    /// words — did nothing, and only a 24×14 capsule at the far edge did (owner
    /// decision 2, H-002). Here the switch is found the way an assistive client
    /// finds it, and it has to be one checkbox named by its row, carrying an
    /// on/off value, as wide as the row.
    ///
    /// Redesign 2026-10-15 (spec §10): the pane shows one section at a time and the
    /// row is the form's 354 pt, not the old list's 480 — the widths below are the
    /// form's. Only the privacy covers are pressed: they live in the isolated
    /// suite, and the press itself is the style's one code path, which
    /// `testPressingAnywhereOnTheRowFlipsTheSwitch` holds for any binding.
    /// Launch at Login is never pressed — it would register the test binary with
    /// `SMAppService`.
    func testEveryToggleRowIsOneSwitchTheWidthOfItsRow() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores

        // Every switch the table draws, by section, with the defaults the
        // isolated suite reads. "Charging" is drawn only on a Mac with a battery to
        // report on (`AmbientWatch.hasBattery`), and a CI virtual machine has none:
        // the row is not there to count, which is correct and not a missing switch.
        let expected: [SettingsSection: [String]] = [
            .general: ["Launch at Login", "Open on Hover"] + (AmbientWatch.hasBattery ? ["Charging"] : [])
                + ["Headphones Connecting", "New Tracks"],
            .privacy: ["Clipboard History", "Include Images", "Keep Pinned Items",
                       PrivacyMode.Section.clipboard.settingsTitle, PrivacyMode.Section.translate.settingsTitle,
                       "Hide from Screen Recording"],
            .music: ["Music Only", "Volume and Output", "Lyric Band"],
            .lyrics: ["Show Lyrics", "Word Karaoke", "Translate Lyrics", "Look Up Lyrics Online"],
            .lockScreen: ["Show on Lock Screen", "Rest as Banner"],
            .translate: ["Translate Online", "Keep History", "Speak Button"],
            .screenshots: ["Save Clipboard Screenshots", "Show Screen Captures"],
            .about: ["Check for Updates Automatically"],
        ]
        var total = 0
        for (section, titles) in expected {
            let root = await SettingsFixture.tree(isolated, section: section)
            let switches = root.all(role: "AXCheckBox")
            XCTAssertEqual(Set(switches.map(\.label)), Set(titles.map { localized($0) }),
                           "\(section) draws exactly these switches\n\(root.dump)")
            for title in titles {
                XCTAssertEqual(switches.filter { $0.label == localized(title) }.count, 1,
                               "exactly one switch named \(title)\n\(root.dump)")
            }
            for node in switches {
                XCTAssertFalse(node.label.isEmpty, "a switch with no name\n\(root.dump)")
                XCTAssertTrue(["0", "1"].contains(node.value), "\(node.label) has no on/off value: \(node.value)")
                let frame = node.frame ?? .zero
                XCTAssertGreaterThanOrEqual(frame.width, 340, "\(node.label) is \(frame.size), not the row")
                XCTAssertGreaterThanOrEqual(frame.height, 24, "\(node.label) is \(frame.size), not the row")
            }
            total += switches.count
        }
        XCTAssertGreaterThanOrEqual(total, 20, "the sections hold the pane's switches")

        let root = await SettingsFixture.tree(isolated, section: .privacy)
        let switches = root.all(role: "AXCheckBox")
        for section in PrivacyMode.Section.allCases {
            let before = stores.privacy.covers(section)
            guard let node = switches.first(where: { $0.label == section.settingsTitle }) else {
                XCTFail("no switch for \(section.settingsTitle)\n\(root.dump)")
                continue
            }
            XCTAssertTrue(node.press(), "\(section.settingsTitle) refused the press")
            let after = await root.reread()
            XCTAssertEqual(stores.privacy.covers(section), !before, "pressing \(section.settingsTitle) did not flip it")
            let reread = after.all(role: "AXCheckBox").first { $0.label == section.settingsTitle }
            XCTAssertEqual(reread?.value, before ? "0" : "1", "\(section.settingsTitle) still reads its old value")
        }
    }

    /// The press is the row's, for any binding: a click on the words lands on
    /// the same action as a click on the track, and the value it vends follows.
    func testPressingAnywhereOnTheRowFlipsTheSwitch() async {
        var writes: [Bool] = []
        let root = await AXProbe.tree(
            of: SwitchHarness { writes.append($0) }.frame(width: 440, height: 26),
            size: CGSize(width: 440, height: 26)
        )
        guard let row = root.all(role: "AXCheckBox").first else {
            return XCTFail("the row is not a switch\n\(root.dump)")
        }
        XCTAssertEqual(row.label, "Row", root.dump)
        XCTAssertEqual(row.value, "0", root.dump)
        XCTAssertGreaterThanOrEqual(row.frame?.width ?? 0, 400, root.dump)

        XCTAssertTrue(row.press())
        let on = await root.reread()
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(on.all(role: "AXCheckBox").first?.value, "1", on.dump)

        XCTAssertTrue(on.all(role: "AXCheckBox").first?.press() ?? false)
        _ = await root.reread()
        XCTAssertEqual(writes, [true, false])
    }

    /// On and off say so by the track, not only by which side the knob is on.
    ///
    /// The panel never becomes key outside Translate, so AppKit drew every
    /// switch in its inactive style: Charging on and Launch at Login off
    /// differed by knob side and a slightly lighter track (H-002). The look is
    /// a function of the state and of Increase Contrast only — no key status
    /// goes in, so none can take the colour away.
    func testTheSwitchShowsItsStateWithoutKeyStatus() {
        let on = PanelSwitchStyle.look(isOn: true, increaseContrast: false)
        XCTAssertEqual(on.track, .accent)
        XCTAssertEqual(on.knob, .trailing)
        XCTAssertEqual(on.outlineWidth, 0)

        let off = PanelSwitchStyle.look(isOn: false, increaseContrast: false)
        XCTAssertEqual(off.track, .well)
        XCTAssertEqual(off.knob, .leading)
        XCTAssertEqual(off.outlineWidth, 0)

        for isOn in [false, true] {
            XCTAssertGreaterThan(PanelSwitchStyle.look(isOn: isOn, increaseContrast: true).outlineWidth, 0,
                                 "Increase Contrast outlines the track, on and off")
        }
    }

    // MARK: - Automation access (M-38, J-027)

    /// A refused player says so, by name, and the row under it leads to the
    /// one place the refusal can be undone. Before this the only sign of a
    /// refused Spotify was a missing heart, shuffle and repeat, and on the
    /// fallback a playing Spotify that never showed at all (J-027).
    func testARefusedPlayerPointsToAutomationSettings() {
        let rows = SettingsPane.automationRows([.spotify: .denied])
        XCTAssertEqual(rows, [
            .status(player: "Spotify", bundleID: "com.spotify.client", state: localized("Not allowed")),
            .note(localized("Isla cannot read a player it is not allowed to control. Allow Isla under Privacy & Security › Automation.")),
            .openAutomationSettings,
        ])
        XCTAssertEqual(
            SettingsPane.automationSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )
    }

    /// Only states Isla actually read are shown. A player that is not running
    /// answers the read-only check with procNotFound, which says nothing about
    /// consent; drawing it as "Not asked yet" would be a guess.
    func testAnUnknownStateIsNotShown() {
        XCTAssertEqual(SettingsPane.automationRows([:]), [])
        XCTAssertEqual(SettingsPane.automationRows([.music: .unknown, .spotify: .unknown]), [])
        XCTAssertEqual(SettingsPane.automationRows([.music: .allowed, .spotify: .unknown]), [
            .status(player: PlayerApp.music.displayName, bundleID: "com.apple.Music", state: localized("Allowed")),
        ])
    }

    /// One row per known player, in a fixed order, and the note and the
    /// action once, only while something is refused: "Not asked yet" needs
    /// no recovery, because the first panel open on Music asks.
    func testEveryReadableStateHasARowAndOnlyARefusalHasTheAction() {
        XCTAssertEqual(SettingsPane.automationRows([.spotify: .notAsked, .music: .allowed]), [
            .status(player: PlayerApp.music.displayName, bundleID: "com.apple.Music", state: localized("Allowed")),
            .status(player: "Spotify", bundleID: "com.spotify.client", state: localized("Not asked yet")),
        ])
        let bothRefused = SettingsPane.automationRows([.spotify: .denied, .music: .denied])
        XCTAssertEqual(bothRefused.filter { $0 == .openAutomationSettings }.count, 1)
        XCTAssertEqual(bothRefused.prefix(2), [
            .status(player: PlayerApp.music.displayName, bundleID: "com.apple.Music", state: localized("Not allowed")),
            .status(player: "Spotify", bundleID: "com.spotify.client", state: localized("Not allowed")),
        ])
    }

    /// The rows are drawn, not only computed: a refused Spotify reads as one
    /// element with its state, and the action is a button by its title — in the
    /// Music section's Automation group, the one place in Settings that says it
    /// (spec §10).
    func testTheMusicSectionDrawsARefusal() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let access = AutomationAccess()
        access.learn(.spotify, outcome: AutomationAccess.refused)
        let root = await SettingsFixture.tree(isolated, section: .music, height: 900, automation: access)
        let refused = localized("Not allowed")
        // One element carrying both, so VoiceOver never reads the state as a
        // stray line after the name.
        let read = { (node: AXNode) in node.label + " " + node.value }
        XCTAssertFalse(root.all { read($0).contains("Spotify") && read($0).contains(refused) }.isEmpty,
                       "no row reading Spotify, \(refused)\n\(root.dump)")
        XCTAssertEqual(root.all(role: "AXButton").filter { $0.label == localized("Open Automation Settings…") }.count, 1,
                       root.dump)
        XCTAssertTrue(root.all(role: "AXHeading").contains { $0.label == localized("Automation") }, root.dump)
    }

    /// ly/READ-02: "Show next line early" is one radio group of four options
    /// — Off, Auto, 0.3 s, 0.5 s — with Auto on until the listener chooses,
    /// and the old 0.25 s and 0.75 s gone. The row sits on a LyricsStore over a
    /// private suite: the pane's own store reads the owner's real defaults,
    /// where a stored 0.5 s from READ-01 would make Auto look unselected.
    func testShowNextLineEarlyOffersFourOptionsWithAutoSelected() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let lyrics = LyricsStore(
            offsetsDirectory: isolated.temp.appendingPathComponent("offsets"), defaults: isolated.suite
        )
        let root = await SettingsFixture.tree(isolated, section: .lyrics, height: 900, lyrics: lyrics)
        let group = try XCTUnwrap(
            root.all(role: "AXRadioGroup").first { $0.label == localized("Show next line early") },
            root.dump
        )
        let buttons = group.all(role: "AXRadioButton")
        let name = { (node: AXNode) in node.title.isEmpty ? node.label : node.title }
        XCTAssertEqual(buttons.map(name), ["Off", "Auto", "0.3 s", "0.5 s"].map { localized($0) }, root.dump)
        XCTAssertEqual(buttons.filter { $0.value == "1" }.map(name), [localized("Auto")], root.dump)
        XCTAssertTrue(root.all { name($0) == localized("0.25 s") || name($0) == localized("0.75 s") }.isEmpty, root.dump)
    }

    // MARK: - Settings › Spotify

    /// A grant Spotify revoked used to leave Settings offering a bare Connect
    /// with no word about why the account had gone.
    func testARevokedAccountOffersReconnect() {
        let rows = SettingsPane.spotifyRows(connected: false, needsReconnect: true, signIn: nil, apiBlocked: false)

        XCTAssertEqual(rows.prefix(2), [
            .note(localized("Spotify ended Isla's access. Connect again to use Liked Songs.")),
            .connect,
        ])
    }

    /// Cancel on the consent page and a sign-in that did not finish each get
    /// their own sentence; both used to return silently.
    func testACancelledSignInSaysSo() {
        let cancelled = SettingsPane.spotifyRows(connected: false, needsReconnect: false, signIn: .cancelled, apiBlocked: false)
        XCTAssertEqual(cancelled.first, .note(localized("Spotify sign-in was cancelled.")))
        XCTAssertTrue(cancelled.contains(.connect))

        for outcome in [SpotifyAccount.SignInOutcome.expired, .failed] {
            let rows = SettingsPane.spotifyRows(connected: false, needsReconnect: false, signIn: outcome, apiBlocked: false)
            XCTAssertEqual(rows.first, .note(localized("Spotify sign-in did not finish. Try connecting again.")))
        }
    }

    /// One event, one note: an outcome replaces the reconnect note rather than
    /// stacking under it, and a local problem leads.
    func testOneEventGetsOneNote() {
        let rows = SettingsPane.spotifyRows(connected: false, needsReconnect: true, signIn: .cancelled, apiBlocked: false)
        XCTAssertEqual(rows.filter { if case .note = $0 { return true } else { return false } }.count, 1)

        let local = SettingsPane.spotifyRows(
            connected: false, needsReconnect: false, signIn: nil, apiBlocked: false, problem: .browserDidNotOpen
        )
        XCTAssertEqual(local.first, .note(SpotifyAccount.SignInProblem.browserDidNotOpen.explanation))
    }

    /// Disconnect was one unconfirmed click on the account's only action.
    func testDisconnectNeedsASecondPress() {
        let rows = SettingsPane.spotifyRows(connected: true, needsReconnect: false, signIn: nil, apiBlocked: false)

        XCTAssertTrue(rows.contains(.confirm(title: localized("Disconnect Spotify Account"), armedTitle: localized("Disconnect"))))
        XCTAssertTrue(rows.contains(.note(localized("Isla forgets the account on this Mac. Your Spotify library stays as it is."))))
        XCTAssertFalse(rows.contains(.connect))
    }

    /// The lock-card heart writes to Liked Songs from a locked Mac; Settings
    /// says so while an account is connected, and not otherwise.
    func testTheHeartIsDisclosed() {
        let heart = SettingsPane.SpotifyRow.note(localized("The heart on the lock screen adds the song to your Liked Songs."))
        let connected = SettingsPane.spotifyRows(connected: true, needsReconnect: false, signIn: nil, apiBlocked: false)
        let disconnected = SettingsPane.spotifyRows(connected: false, needsReconnect: false, signIn: nil, apiBlocked: false)

        XCTAssertTrue(connected.contains(heart))
        XCTAssertFalse(disconnected.contains(heart))
    }

    /// The Import row stays offered while there is something to import, and a
    /// refusal explains the missing heart only while connected.
    func testImportAndRefusalRows() {
        let importing = SettingsPane.spotifyRows(
            connected: false, needsReconnect: false, signIn: nil, apiBlocked: false, canImport: true
        )
        XCTAssertEqual(importing.last, .importAccount)

        let refused = SettingsPane.spotifyRows(
            connected: true, needsReconnect: false, signIn: nil, apiBlocked: true, refusal: .premiumRequired
        )
        XCTAssertTrue(refused.contains(.note(SpotifyAccount.Refusal.premiumRequired.explanation)))
        let unrefused = SettingsPane.spotifyRows(
            connected: true, needsReconnect: false, signIn: nil, apiBlocked: false, refusal: .premiumRequired
        )
        XCTAssertFalse(unrefused.contains(.note(SpotifyAccount.Refusal.premiumRequired.explanation)))
    }
}

/// A row switch over a binding the test can watch, re-rendered by its own
/// state so the value an assistive client reads after a press is the new one.
private struct SwitchHarness: View {
    let changed: (Bool) -> Void
    @State private var isOn = false

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0; changed($0) })) {
            Text(verbatim: "Row")
        }
        .toggleStyle(PanelSwitchStyle())
    }
}

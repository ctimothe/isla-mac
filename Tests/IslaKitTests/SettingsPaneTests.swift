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
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 700))
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
    /// Only the privacy covers are pressed. Every other row writes to
    /// `UserDefaults.standard` — the test runner's own domain, which has leaked
    /// settings into later runs before — and Launch at Login would register
    /// the test binary with `SMAppService`. The covers live in the isolated
    /// suite, so they can be flipped without touching anything of the owner's;
    /// the press itself is the style's one code path, which
    /// `testPressingAnywhereOnTheRowFlipsTheSwitch` holds for any binding.
    func testEveryToggleRowIsOneSwitchTheWidthOfItsRow() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 700))

        let switches = root.all(role: "AXCheckBox")
        // Sixteen rows can be on screen with the defaults the runner reads;
        // the count is a floor so a section that hides a row behind another
        // setting cannot make this flaky, and an empty list cannot pass.
        XCTAssertGreaterThanOrEqual(switches.count, 12, root.dump)
        for title in ["Launch at Login", "Open on Hover", "Show Charging", "Clipboard History",
                      PrivacyMode.Section.clipboard.settingsTitle, PrivacyMode.Section.translate.settingsTitle,
                      "Hide from Screen Recording"] {
            XCTAssertEqual(switches.filter { $0.label == localized(title) }.count, 1,
                           "exactly one switch named \(title)\n\(root.dump)")
        }
        for node in switches {
            XCTAssertFalse(node.label.isEmpty, "a switch with no name\n\(root.dump)")
            XCTAssertTrue(["0", "1"].contains(node.value), "\(node.label) has no on/off value: \(node.value)")
            let frame = node.frame ?? .zero
            XCTAssertGreaterThanOrEqual(frame.width, 400, "\(node.label) is \(frame.size), not the row")
            XCTAssertGreaterThanOrEqual(frame.height, 24, "\(node.label) is \(frame.size), not the row")
        }

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
    /// switch in its inactive style: Show Charging on and Launch at Login off
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
            .status(player: "Spotify", state: localized("Not allowed")),
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
            .status(player: PlayerApp.music.displayName, state: localized("Allowed")),
        ])
    }

    /// One row per known player, in a fixed order, and the note and the
    /// action once, only while something is refused: "Not asked yet" needs
    /// no recovery, because the first panel open on Music asks.
    func testEveryReadableStateHasARowAndOnlyARefusalHasTheAction() {
        XCTAssertEqual(SettingsPane.automationRows([.spotify: .notAsked, .music: .allowed]), [
            .status(player: PlayerApp.music.displayName, state: localized("Allowed")),
            .status(player: "Spotify", state: localized("Not asked yet")),
        ])
        let bothRefused = SettingsPane.automationRows([.spotify: .denied, .music: .denied])
        XCTAssertEqual(bothRefused.filter { $0 == .openAutomationSettings }.count, 1)
        XCTAssertEqual(bothRefused.prefix(2), [
            .status(player: PlayerApp.music.displayName, state: localized("Not allowed")),
            .status(player: "Spotify", state: localized("Not allowed")),
        ])
    }

    /// The rows are drawn, not only computed: a refused Spotify reads as one
    /// element with its state, and the action is a button by its title.
    func testTheMusicSectionDrawsARefusal() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        let access = AutomationAccess()
        access.learn(.spotify, outcome: AutomationAccess.refused)
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }),
            automation: access
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 900))
        let refused = localized("Not allowed")
        // One element carrying both, so VoiceOver never reads the state as a
        // stray line after the name.
        let read = { (node: AXNode) in node.label + " " + node.value }
        XCTAssertFalse(root.all { read($0).contains("Spotify") && read($0).contains(refused) }.isEmpty,
                       "no row reading Spotify, \(refused)\n\(root.dump)")
        XCTAssertEqual(root.all(role: "AXButton").filter { $0.label == localized("Open Automation Settings…") }.count, 1,
                       root.dump)
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

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
                      PrivacyMode.Section.clipboard.title, PrivacyMode.Section.translate.title,
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
            guard let node = switches.first(where: { $0.label == section.title }) else {
                XCTFail("no switch for \(section.title)\n\(root.dump)")
                continue
            }
            XCTAssertTrue(node.press(), "\(section.title) refused the press")
            let after = await root.reread()
            XCTAssertEqual(stores.privacy.covers(section), !before, "pressing \(section.title) did not flip it")
            let reread = after.all(role: "AXCheckBox").first { $0.label == section.title }
            XCTAssertEqual(reread?.value, before ? "0" : "1", "\(section.title) still reads its old value")
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

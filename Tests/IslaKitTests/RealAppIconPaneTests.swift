import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The panes that name a music app, drawn over a Mac whose apps the test
/// chooses (`SettingsFixture.macWithApps`): the Players on This Mac group, the
/// Automation rows' icons and the empty player's Open buttons. Nothing here
/// reads what the runner has installed, and no brand's artwork is involved —
/// every icon is a blank image; what is held is which apps are named, in what
/// order, and that nothing is truncated.
@MainActor
final class RealAppIconPaneTests: XCTestCase {
    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    private let mac: [String: String] = [
        "com.apple.Music": "Музыка",
        "com.spotify.client": "Spotify",
        "ru.yandex.desktop.music": "Яндекс Музыка",
        "com.deezer.deezer-desktop": "Deezer",
        "ru.keepcoder.Telegram": "Telegram",
        "com.tdesktop.Telegram": "Telegram Desktop",
        "com.apple.podcasts": "Подкасты",
    ]

    // MARK: Settings › Music › Players on This Mac

    /// One row per installed player, named as VoiceOver reads it: Apple Music,
    /// Spotify, then the rest by name, both Telegram builds, the podcast app
    /// among them. Read-only labels: no button, no switch.
    func testThePlayersGroupListsEveryInstalledPlayerInOrder() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .music, icons: SettingsFixture.macWithApps(mac))
        let labels = root.flattened.map(\.label)
        // Deezer sorts among the Latin names, ahead of Telegram.
        let ordered = ["Apple Music", "Spotify", "Deezer", "Telegram", "Telegram Desktop", "Подкасты", "Яндекс Музыка"]
        var cursor = labels.startIndex
        for name in ordered {
            guard let found = labels[cursor...].firstIndex(of: name) else {
                return XCTFail("\(name) is missing or out of order\n\(root.dump)")
            }
            cursor = labels.index(after: found)
        }
        XCTAssertTrue(labels.contains("Players on This Mac"), root.dump)
        // The header comes before the first player, after Music Only.
        let header = labels.firstIndex(of: "Players on This Mac")!
        XCTAssertLessThan(labels.firstIndex(of: localized("Music Only"))!, header)
        XCTAssertLessThan(header, labels.firstIndex(of: "Apple Music")!)
        XCTAssertTrue(root.dump.contains(localized("These players always show, except Telegram, which shows songs but not videos. Any other app shows when it says it is playing audio.")), root.dump)
        // Read-only: none of the player rows is a control. (Spotify is also the
        // name of a sidebar button, which is a control and is not this row.)
        for name in ordered where name != "Spotify" {
            XCTAssertTrue(root.all { $0.label == name && ($0.role == "AXButton" || $0.role == "AXCheckBox") }.isEmpty, name)
        }
    }

    func testNoPlayerInstalledDrawsNoGroup() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .music)
        XCTAssertFalse(root.dump.contains("Players on This Mac"), root.dump)
    }

    func testThePlayersGroupReadsInRussian() async {
        LabLocalization.use("ru")
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(
            isolated, section: .music, bodyWidth: 480, icons: SettingsFixture.macWithApps(mac)
        )
        XCTAssertTrue(root.dump.contains("Плееры на этом Mac"), root.dump)
        XCTAssertTrue(root.dump.contains("Яндекс Музыка"), root.dump)
    }

    // MARK: The empty player's buttons

    private func emptyPlayer(icons: AppIcons, bodyWidth: CGFloat) async -> (AXNode, PlayerLayout) {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let layout = PlayerLayout(bodyWidth: bodyWidth)
        let pane = MediaPane(
            media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil,
            audio: AudioWatch(read: { ([], 0, nil) }, readMuted: { false }, installListeners: {}, removeListeners: {}),
            icons: icons
        )
        .defaultAppStorage(isolated.suite)
        return (await AXProbe.tree(of: pane, size: layout.paneSize), layout)
    }

    /// Apple Music and Spotify lead, then the others by name; no more than
    /// three; none is a podcast app or Telegram; and every button is whole
    /// inside the pane, 22 tall, 8 apart.
    func testTheEmptyPlayerOffersTheInstalledMusicAppsInOrderUpToThree() async throws {
        for width in [CGFloat(480), 560, 620] {
            let (root, layout) = await emptyPlayer(icons: SettingsFixture.macWithApps(mac), bodyWidth: width)
            let buttons = root.all { $0.role == "AXButton" }
            XCTAssertFalse(buttons.isEmpty, "\(width)\n\(root.dump)")
            XCTAssertLessThanOrEqual(buttons.count, 3, "\(width)")
            let order = ["Open Apple Music", "Open Spotify", "Open Deezer"]
            XCTAssertEqual(buttons.map(\.label), Array(order.prefix(buttons.count)), "\(width)\n\(root.dump)")
            XCTAssertFalse(root.dump.contains("Telegram"), "Telegram is not a player to start a song in")
            XCTAssertFalse(root.dump.contains("Подкасты"), "nor is a podcast app")
            let pane = CGRect(origin: .zero, size: layout.paneSize)
            for button in buttons {
                let frame = try XCTUnwrap(button.frame)
                XCTAssertTrue(pane.contains(frame), "\(button.label) \(frame) leaves \(pane) at \(width)")
                XCTAssertEqual(frame.height, PlayerLayout.EmptyFrames.buttonHeight, accuracy: 1)
            }
            for (a, b) in zip(buttons, buttons.dropFirst()) {
                XCTAssertEqual(try XCTUnwrap(b.frame).minX - (try XCTUnwrap(a.frame)).maxX,
                               PlayerLayout.EmptyFrames.buttonSpacing, accuracy: 1)
            }
        }
    }

    /// Without Apple Music or Spotify installed the other music apps are still
    /// offered, and a Mac with no music app offers none.
    func testTheEmptyPlayerOffersWhatIsInstalled() async {
        let (some, _) = await emptyPlayer(icons: SettingsFixture.macWithApps(["com.deezer.deezer-desktop": "Deezer"]), bodyWidth: 560)
        XCTAssertEqual(some.all { $0.role == "AXButton" }.map(\.label), ["Open Deezer"])
        let (none, _) = await emptyPlayer(icons: SettingsFixture.macWithApps([:]), bodyWidth: 560)
        XCTAssertTrue(none.all { $0.role == "AXButton" }.isEmpty)
    }
}

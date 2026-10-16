import SwiftUI
import XCTest
@testable import IslaKit

/// Settings → About with the update card, drawn for real over fakes and read the
/// way VoiceOver reads it: the words are there, each state offers the buttons it
/// should, and the buttons are wired to the installer — which in these tests is
/// a fake one, so no press starts a download.
@MainActor
final class UpdateCardTests: XCTestCase {
    private func knownUpdate() async throws -> UpdateCheck {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v0.3.1", "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1",
            "body": "- Fixed the lyric sweep.\n- Faster start.",
            "assets": [
                ["name": "Isla-0.3.1.dmg", "size": 9, "browser_download_url": "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"],
                ["name": "Isla-0.3.1.dmg.sig", "size": 13, "browser_download_url": "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg.sig"],
            ],
        ] as [String: Any])
        let check = UpdateCheck(
            fetch: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            currentVersion: { "0.3.0" }
        )
        check.check()
        for _ in 0..<400 where check.lastAvailable == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(check.lastAvailable)
        return check
    }

    func testAnAvailableUpdateReadsAndOffersUpdateNow() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.imageData = Data("123456789".utf8)       // 9 bytes, as advertised
        rig.downloader.signatureData = Data("abcdefghijklm".utf8) // 13
        rig.build()
        let check = try await knownUpdate()
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .about, updates: check, installer: rig.installer)

        XCTAssertNotNil(root.first(label: "Isla 0.3.1") ?? root.all { $0.value.contains("Isla 0.3.1") || $0.label.contains("Isla 0.3.1") }.first, root.dump)
        XCTAssertTrue(root.dump.contains("Update available"), root.dump)
        XCTAssertTrue(root.dump.contains("Fixed the lyric sweep."), root.dump)
        let now = try XCTUnwrap(root.first(label: "Update Now"), root.dump)
        XCTAssertNotNil(root.first(label: "More Info…"), root.dump)
        XCTAssertNil(root.first(label: "Check for Updates"), "nothing to check while an update is on offer")

        XCTAssertEqual(rig.log.all, [], "drawing the card downloads nothing")
        XCTAssertTrue(now.press(), root.dump)
        await rig.until("the download to start") { rig.log.count("download \(UpdateInstaller.signatureFileName)") == 1 }
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1, "pressing Update Now ran the install")
    }

    func testTheCardNamesWhatItIsDoingWhileItDownloads() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.imageData = Data("123456789".utf8)
        rig.downloader.signatureData = Data("abcdefghijklm".utf8)
        rig.downloader.holdImage = true
        rig.build()
        let check = try await knownUpdate()
        rig.installer.install(check.lastAvailable!)
        await rig.until("the download") { rig.log.count("download \(UpdateInstaller.imageFileName)") == 1 }
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .about, updates: check, installer: rig.installer)
        XCTAssertTrue(root.dump.contains("Downloading Isla 0.3.1…"), root.dump)
        let cancel = try XCTUnwrap(root.first(label: "Cancel"), root.dump)
        XCTAssertNil(root.first(label: "Update Now"))
        XCTAssertNotNil(root.all { $0.role == "AXProgressIndicator" || $0.label == "Downloading Isla 0.3.1…" }.first, root.dump)
        XCTAssertTrue(cancel.press())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .idle)
    }

    func testAManualOnlyBuildOffersTheDownloadPage() async throws {
        let check = try await knownUpdate()
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        // The pane's own default installer cannot install: the app "lives" on a volume.
        let root = await SettingsFixture.tree(isolated, section: .about, updates: check)
        XCTAssertTrue(root.dump.contains("Isla can't update itself from this location."), root.dump)
        XCTAssertNotNil(root.first(label: "Download Isla 0.3.1"), root.dump)
        XCTAssertNil(root.first(label: "Update Now"), root.dump)
        XCTAssertTrue(root.dump.contains("Quit Isla, then replace it in Applications with the new version."), root.dump)
    }

    func testNothingKnownOffersTheCheck() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .about)
        XCTAssertNotNil(root.first(label: "Check for Updates"), root.dump)
        XCTAssertNil(root.first(label: "Update Now"))
    }

    /// Release notes can hold a link, and a link in the panel must not be a link.
    func testNoLinkInTheNotesIsClickable() {
        let rendered = UpdatePresentation.renderedNotes("See [the page](https://example.com).")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }
}

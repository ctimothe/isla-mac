import SwiftUI
import XCTest
@testable import IslaKit

/// Finding your way around Settings (H-003, F-048).
///
/// The pane is a 162 pt window onto about a thousand points of rows, and it
/// ended on a clean card edge after five switches: nothing said there was
/// more. Quit — the only way out of an app that Force Quit does not list —
/// was the last row, past y = 1000, and Privacy, the section a person about
/// to share their screen comes looking for, was the eighth of nine. About
/// was ordered front without activating Isla, so it could open behind the
/// app in front.
@MainActor
final class SettingsWayfindingTests: XCTestCase {
    /// The pane's own size in the panel at the default width, as the
    /// 2026-10-11 dump measured it.
    private static let viewport = CGSize(width: 488, height: 162)

    private func probePane(height: CGFloat) async -> (AXNode, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: Self.viewport.width, height: height))
        return (root, isolated)
    }

    /// Quit and About are on screen the moment Settings opens, without a
    /// scroll: pinned in a footer under the scrolling rows rather than at
    /// the end of them.
    func testQuitAndAboutAreVisibleWithoutScrolling() async {
        let (root, isolated) = await probePane(height: Self.viewport.height)
        defer { isolated.release() }
        for label in [localized("Quit"), localized("About %@", ProductIdentity.displayName)] {
            let buttons = root.all { $0.role == "AXButton" && $0.label == label }
            XCTAssertEqual(buttons.count, 1, "\(label) should be one button\n\(root.dump)")
            guard let frame = buttons.first?.frame else {
                XCTFail("\(label) has no frame\n\(root.dump)")
                continue
            }
            XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(label) at \(frame)\n\(root.dump)")
            XCTAssertLessThanOrEqual(frame.maxY, Self.viewport.height, "\(label) at \(frame)\n\(root.dump)")
        }
    }

    /// Privacy is the second section, straight after General: it is what a
    /// person about to share their screen opens Settings for, and it sat at
    /// y ≈ 900, under Spotify.
    func testPrivacyComesRightAfterGeneral() async {
        let (root, isolated) = await probePane(height: 1400)
        defer { isolated.release() }
        let headings = root.all { $0.role == "AXHeading" }.map(\.label)
        XCTAssertEqual(Array(headings.prefix(2)), [localized("General"), localized("Privacy")], root.dump)
    }

    /// About activates Isla so its window comes to the front, and gives the
    /// keyboard back when it closes — the lease Quick Look and AirDrop have
    /// always taken. Driven with a fake frontmost app: nothing real is
    /// activated.
    func testAboutHandsActivationBack() {
        let isla: pid_t = 7
        var front: pid_t? = 42
        var islaActivations = 0
        var activated: [pid_t] = []
        let lease = ActivationLease(
            ownPID: isla,
            frontmostPID: { front },
            activateSelf: { islaActivations += 1; front = isla },
            activate: { activated.append($0); front = $0 }
        )

        // The app in front is remembered, Isla comes forward, and on close
        // the remembered app is handed the keyboard back, once.
        lease.begin()
        XCTAssertEqual(islaActivations, 1)
        XCTAssertEqual(front, isla)
        lease.end()
        XCTAssertEqual(activated, [42])
        lease.end()
        XCTAssertEqual(activated, [42], "a second end hands nothing back")

        // Someone who clicked into a third app meanwhile already chose where
        // the keyboard goes: the window closing does not take it from them.
        lease.begin()
        front = 99
        lease.end()
        XCTAssertEqual(activated, [42])

        // Isla already in front: there is nobody to hand back to.
        front = isla
        lease.begin()
        lease.end()
        XCTAssertEqual(activated, [42])
        XCTAssertEqual(islaActivations, 3, "begin always activates")
    }
}

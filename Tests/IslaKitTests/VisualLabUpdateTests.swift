import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Settings → About in every state an update can put it in: the card Update Now
/// grows, drawn without a release, a download, a mount or an app being replaced.
///
/// Each shot stands a fake `UpdateCheck` and a fake `UpdateInstaller` in front of
/// the real ones (`sharedOverride`), puts the installer in the phase it means to
/// draw (`presentForTests`), and photographs the panel the way a person sees it.
/// Run with `Scripts/visual-lab.sh <folder> VisualLabUpdateTests`.
@MainActor
final class VisualLabUpdateTests: VisualLabCase {

    enum Scene: String, CaseIterable {
        case upToDate = "up-to-date"
        case checking
        case available
        case downloading
        case verifying
        case installing
        case relaunching
        case failedSignature = "failed-signature"
        case failedOffline = "failed-offline"
        case manualLocation = "manual-location"
        case manualDownloadPage = "manual-download-page"
        // Added with the review fixes (2026-10-16).
        case restartNeeded = "restart-needed"
        case failedCannotOpen = "failed-cannot-open"

        static let first: [Scene] = [
            .upToDate, .checking, .available, .downloading, .verifying, .installing, .relaunching,
            .failedSignature, .failedOffline, .manualLocation, .manualDownloadPage,
        ]
        static let added: [Scene] = [.restartNeeded, .failedCannotOpen]
    }

    private let notes = """
    ## What's new
    - Lyrics hold still under a resting hand.
    - The output button shows where the sound goes.
    - Isla keeps its Accessibility permission across updates.
    - Fixes a rare crash when a display is unplugged.

    Full notes on the [release page](https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1).
    """

    private func answer(version: String, withAssets: Bool = true) -> Data {
        let base = "https://github.com/ctimothe/isla-mac/releases/download/v\(version)/"
        var object: [String: Any] = [
            "tag_name": "v\(version)", "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v\(version)",
            "body": notes,
        ]
        if withAssets {
            object["assets"] = [
                ["name": "Isla-\(version).dmg", "size": 9_800_000, "browser_download_url": base + "Isla-\(version).dmg"],
                ["name": "Isla-\(version).dmg.sig", "size": 88, "browser_download_url": base + "Isla-\(version).dmg.sig"],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// An installer on a Mac where Update Now is possible, over nothing: every
    /// collaborator is the production one, and none is ever called.
    private func installableInstaller() -> UpdateInstaller {
        UpdateInstaller(environment: UpdateEnvironment(
            installedURL: URL(fileURLWithPath: "/Users/lab/Applications/Isla.app"),
            publicKey: UpdateTestSupport.Key().publicBase64, processID: 1,
            availableCapacity: { _ in nil }, isWritable: { _ in true },
            canReplace: { _ in true }, containsMount: { _ in false },
            scratchRoot: FileManager.default.temporaryDirectory,
            makeScratchFolder: { throw CocoaError(.fileWriteNoPermission) }
        ))
    }

    /// Puts a scene in place: the check says what it found, the installer is in
    /// the phase, and both stand in front of the real ones.
    private func stage(_ scene: Scene) async throws {
        let running = "0.3.0"
        let fetch: UpdateCheck.Fetch
        switch scene {
        case .upToDate:
            let data = answer(version: running)
            fetch = { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        case .checking:
            fetch = { _ in try await Task.sleep(for: .seconds(3600)); throw URLError(.timedOut) }
        case .manualDownloadPage:
            let data = answer(version: "0.3.1", withAssets: false)
            fetch = { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        default:
            let data = answer(version: "0.3.1")
            fetch = { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        }
        let check = UpdateCheck(fetch: fetch, currentVersion: { running })
        check.check()
        if scene != .checking {
            for _ in 0..<400 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        }
        UpdateCheck.sharedOverride = check

        let installer = scene == .manualLocation
            ? UpdateInstaller(environment: .neverInstalls)
            : installableInstaller()
        let release = check.lastAvailable
        switch scene {
        case .downloading: installer.presentForTests(.downloading(received: 3_920_000, total: 9_800_000), release: release)
        case .verifying: installer.presentForTests(.verifying, release: release)
        case .installing: installer.presentForTests(.installing, release: release)
        case .relaunching: installer.presentForTests(.relaunching, release: release)
        case .failedSignature: installer.presentForTests(.failed(.signature), release: release)
        case .failedOffline: installer.presentForTests(.failed(.offline), release: release)
        case .restartNeeded: installer.presentForTests(.restartNeeded, release: release)
        case .failedCannotOpen: installer.presentForTests(.failed(.cannotOpen), release: release)
        default: break
        }
        UpdateInstaller.sharedOverride = installer
    }

    func testAboutUpdateStates() async throws {
        let session = try makeSession()
        addTeardownBlock { @MainActor in
            UpdateCheck.sharedOverride = nil
            UpdateInstaller.sharedOverride = nil
        }
        let shoot = LabPhotographer(session: session, surface: "panel-settings-update")
        let size = CGSize(width: VisualLab.windowSize.width, height: 460)
        let notes: [Scene: String] = [
            .upToDate: "No update: Isla 0.3.0 is the latest. Check for Updates asks GitHub once.",
            .checking: "A check in flight: the spinner and no button.",
            .available: "Isla 0.3.1 on offer with its size and notes (six lines at most); Update Now is the prominent button.",
            .downloading: "About 40 percent of 9.8 MB, with Cancel.",
            .verifying: "The signature is checked before the image is mounted; an endless bar, no button.",
            .installing: "Mounting, staging and swapping; an endless bar, no button.",
            .relaunching: "The last state before Isla quits and the new copy opens.",
            .failedSignature: "A download that did not match Isla's signature: deleted, with Try Again.",
            .failedOffline: "GitHub could not be reached: Try Again.",
            .manualLocation: "Isla runs from a place it cannot replace itself in: only the download page is offered.",
            .manualDownloadPage: "A release with no signature: only the download page is offered.",
        ]
        for scene in Scene.first {
            try await shoot.shoot(scene.rawValue, variants: [.base, .light, .russian], size: size, settle: 0.4,
                                  notes: notes[scene]) { variant in
                try await self.stage(scene)
                return Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                    vm.settingsSection = .about
                }), variant, height: size.height)
            }
        }
        try await shoot.shoot("available", variants: [LabVariant(name: "ru-w480", width: 480, language: "ru"), .w480],
                              size: size, settle: 0.4, notes: "The longest copy at the narrowest panel.") { variant in
            try await self.stage(.available)
            return Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                vm.settingsSection = .about
            }), variant, height: size.height)
        }
        try await shoot.shoot("downloading", variants: [.motion], size: size, settle: 0.4,
                              notes: "Reduce Motion: the bar steps and nothing sweeps.") { variant in
            try await self.stage(.downloading)
            return Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                vm.settingsSection = .about
            }), variant, height: size.height)
        }
        try await shoot.shoot("installing", variants: [.motion], size: size, settle: 0.4,
                              notes: "Reduce Motion: the endless bar fades in and out instead of sweeping.") { variant in
            try await self.stage(.installing)
            return Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                vm.settingsSection = .about
            }), variant, height: size.height)
        }
    }

    /// The two states the review added: installed but unable to restart itself, and
    /// an image that would not open or would not detach.
    func testAboutNewUpdateStates() async throws {
        let session = try makeSession()
        addTeardownBlock { @MainActor in
            UpdateCheck.sharedOverride = nil
            UpdateInstaller.sharedOverride = nil
        }
        let shoot = LabPhotographer(session: session, surface: "panel-settings-update")
        let size = CGSize(width: VisualLab.windowSize.width, height: 460)
        let notes: [Scene: String] = [
            .restartNeeded: "The new copy is in place and Isla could not start it: it stays running and asks to be quit.",
            .failedCannotOpen: "The downloaded image would not open or would not detach (or a tool hung): Try Again.",
        ]
        for scene in Scene.added {
            try await shoot.shoot(scene.rawValue, variants: [.base, .light, .russian], size: size, settle: 0.4,
                                  notes: notes[scene]) { variant in
                try await self.stage(scene)
                return Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                    vm.settingsSection = .about
                }), variant, height: size.height)
            }
        }
    }
}

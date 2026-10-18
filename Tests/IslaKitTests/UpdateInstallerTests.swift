import Foundation
import XCTest
@testable import IslaKit

/// Update Now, played out over fakes: the order of the steps, and every way the
/// sequence can stop. Nothing here downloads, mounts or replaces a real app, and
/// the fake relauncher never ends the test process.
@MainActor
final class UpdateInstallerTests: XCTestCase {

    // MARK: The way it goes

    func testTheHappyPathRunsInOrderAndEndsInARelaunch() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.progress = [3, 5, 9]
        rig.build()
        var seenAtRelaunch: [String] = []
        rig.relauncher.onRelaunch = { seenAtRelaunch = rig.leftovers() }
        rig.installer.install(rig.release())
        await rig.finish()

        XCTAssertEqual(rig.log.all, [
            "download \(UpdateInstaller.signatureFileName)", "download \(UpdateInstaller.imageFileName)",
            "verify", "attach", "stage", "detach", "validate", "swap", "relaunch",
        ])
        // The phases the panel shows, in order, without repeats of the same one.
        var kinds: [String] = []
        for phase in rig.phases {
            let kind: String
            switch phase {
            case .idle: kind = "idle"
            case .downloading: kind = "downloading"
            case .verifying: kind = "verifying"
            case .installing: kind = "installing"
            case .relaunching: kind = "relaunching"
            case .restartNeeded: kind = "restart"
            case .failed: kind = "failed"
            case .manualOnly: kind = "manual"
            }
            if kinds.last != kind { kinds.append(kind) }
        }
        XCTAssertEqual(kinds, ["idle", "downloading", "verifying", "installing", "relaunching"])
        // Progress only ever moves forward.
        var last: Int64 = -1
        for case .downloading(let received, let total) in rig.phases {
            XCTAssertGreaterThanOrEqual(received, last)
            XCTAssertEqual(total, Int64(rig.downloader.imageData.count))
            last = received
        }
        XCTAssertEqual(rig.relauncher.calls.count, 1)
        XCTAssertEqual(rig.relauncher.calls.first?.installed, rig.installed)
        XCTAssertEqual(rig.relauncher.calls.first?.processID, 4242)
        // The installed app is now the new one, and nothing of the run is left
        // when the process is about to end in the relaunch.
        XCTAssertEqual(try String(contentsOf: rig.installed.appendingPathComponent("marker.txt"), encoding: .utf8), "new")
        XCTAssertEqual(seenAtRelaunch, [], "temporary files and the staging folder are gone before the relaunch")
        XCTAssertEqual(rig.leftovers(), [])
    }

    func testTheSignatureIsReadFromTheDownloadAndHandedToTheVerifier() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.signatureData = Data("  c2lnbmF0dXJl\n".utf8)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.verifier.seenSignature, "  c2lnbmF0dXJl\n")
        XCTAssertTrue(rig.verifier.imageExisted, "it checks the file on disk")
    }

    // MARK: A download that is not what was signed

    func testABadSignatureFailsBeforeAnythingIsMounted() async throws {
        let rig = try InstallerRig(self)
        rig.verifier.valid = false
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()

        XCTAssertEqual(rig.installer.phase, .failed(.signature))
        XCTAssertEqual(rig.log.count("attach"), 0, "an image that is not Isla's is never attached")
        XCTAssertEqual(rig.log.count("stage"), 0)
        XCTAssertEqual(rig.log.count("swap"), 0)
        XCTAssertEqual(rig.log.count("relaunch"), 0)
        XCTAssertEqual(rig.leftovers(), [], "the download is deleted")
        XCTAssertEqual(rig.scratchFolders.count, 1)
        XCTAssertEqual(rig.installedFingerprint, before)
    }

    func testAnImageOfTheWrongSizeIsRefusedBeforeItIsEvenVerified() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        var release = rig.release()
        release.dmg = .init(name: release.dmg!.name, url: release.dmg!.url, size: release.dmg!.size + 1)
        rig.installer.install(release)
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.signature))
        XCTAssertEqual(rig.log.count("verify"), 0)
        XCTAssertEqual(rig.log.count("attach"), 0)
        XCTAssertEqual(rig.leftovers(), [])
    }

    func testASignatureFileOfTheWrongSizeIsRefused() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        var release = rig.release()
        release.signature = .init(name: release.signature!.name, url: release.signature!.url, size: release.signature!.size + 1)
        rig.installer.install(release)
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.signature))
        XCTAssertEqual(rig.log.count("download \(UpdateInstaller.imageFileName)"), 0, "the signature is fetched first and a bad one stops there")
        XCTAssertEqual(rig.leftovers(), [])
    }

    // MARK: Before anything is downloaded

    private func expectManual(
        _ reason: UpdateInstaller.ManualReason, configure: (InstallerRig) -> Void, release: ((InstallerRig) -> UpdateCheck.Release)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let rig = try InstallerRig(self)
        configure(rig)
        rig.build()
        let target = release?(rig) ?? rig.release()
        XCTAssertEqual(rig.installer.manualReason(for: target), reason, file: file, line: line)
        XCTAssertEqual(rig.installer.phase, .idle, "asking changes nothing", file: file, line: line)
        rig.installer.install(target)
        XCTAssertEqual(rig.installer.phase, .manualOnly(reason), file: file, line: line)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.log.all, [], "nothing was downloaded, mounted or replaced", file: file, line: line)
        XCTAssertEqual(rig.leftovers(), [], file: file, line: line)
        XCTAssertEqual(rig.scratchFolders, [], "no scratch folder was even made", file: file, line: line)
    }

    func testAnAppRunningFromAnAppTranslocationFolderOffersOnlyTheDownload() async throws {
        try await expectManual(.translocated) { rig in
            rig.installedPath = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/Isla.app")
            rig.writable = { _ in true }
        }
    }

    func testAnAppOnAMountedVolumeOffersOnlyTheDownload() async throws {
        try await expectManual(.mountedVolume) { rig in
            rig.installedPath = URL(fileURLWithPath: "/Volumes/Isla/Isla.app")
            rig.writable = { _ in true }
        }
    }

    func testAnAppThatIsNotABundleOffersOnlyTheDownload() async throws {
        try await expectManual(.notAnApp) { rig in
            rig.installedPath = rig.apps.appendingPathComponent("Isla")
        }
    }

    func testAFolderThatCannotBeWrittenToOffersOnlyTheDownload() async throws {
        try await expectManual(.notWritable) { rig in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.apps.path)
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.apps.path) }
        }
    }

    func testABuildWithoutAKeyOffersOnlyTheDownload() async throws {
        try await expectManual(.noPublicKey) { $0.publicKey = nil }
        try await expectManual(.noPublicKey) { $0.publicKey = "not a key" }
        try await expectManual(.noPublicKey) { $0.publicKey = Data(repeating: 1, count: 31).base64EncodedString() }
    }

    func testAReleaseWithoutAnImageOrASignatureOffersOnlyTheDownload() async throws {
        try await expectManual(.noImage, configure: { _ in }, release: { $0.release(image: false) })
        try await expectManual(.noSignature, configure: { _ in }, release: { $0.release(signature: false) })
    }

    /// An asset the installer is handed is checked again against the trust
    /// rules: it is the last thing between a URL and a network request.
    func testAnAssetThatBreaksTheTrustRulesIsNotFetched() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        var release = rig.release()
        release.dmg = .init(name: "Isla-0.3.1.dmg", url: URL(string: "https://evil.example/Isla-0.3.1.dmg")!, size: 9)
        XCTAssertEqual(rig.installer.manualReason(for: release), .noImage)
        release = rig.release()
        release.signature = .init(name: "Isla-0.3.1.dmg.sig", url: URL(string: "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg.sig?x=1")!, size: 9)
        XCTAssertEqual(rig.installer.manualReason(for: release), .noSignature)
    }

    func testTheInstallableCaseHasNoManualReason() throws {
        let rig = try InstallerRig(self)
        rig.build()
        XCTAssertNil(rig.installer.manualReason(for: rig.release()))
    }

    // MARK: Disk space

    func testTooLittleSpaceFailsBeforeDownloading() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.imageData = Data(repeating: 1, count: 1000)
        rig.freeBytes = 2499      // 2.5 x 1000 = 2500
        rig.build()
        rig.installer.install(rig.release())
        XCTAssertEqual(rig.installer.phase, .failed(.diskSpace))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.log.all, [])
        XCTAssertEqual(rig.scratchFolders, [])
    }

    func testTheVolumeTheDownloadLivesOnIsCheckedToo() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.imageData = Data(repeating: 1, count: 1000)
        rig.scratchFreeBytes = 2499
        rig.build()
        rig.installer.install(rig.release())
        XCTAssertEqual(rig.installer.phase, .failed(.diskSpace))
        XCTAssertEqual(rig.log.all, [])
    }

    func testExactlyTwoAndAHalfTimesTheImageIsEnough() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.imageData = Data(repeating: 1, count: 1000)
        rig.freeBytes = 2500
        rig.scratchFreeBytes = 2500
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
    }

    func testUnknownFreeSpaceDoesNotStopTheInstall() async throws {
        let rig = try InstallerRig(self)
        rig.freeBytes = nil
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
    }

    // MARK: Failing on the way

    func testAnUnreachableGitHubIsOffline() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.failure = URLError(.notConnectedToInternet)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.offline))
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.log.count("attach"), 0)
    }

    func testABadStatusIsOfflineToo() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.failure = UpdateDownloadError.badStatus(404)
        rig.downloader.failImageOnly = true
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.offline))
        XCTAssertEqual(rig.leftovers(), [])
    }

    func testAnImageThatWillNotMountIsAnInvalidUpdateAndNothingIsDetached() async throws {
        let rig = try InstallerRig(self)
        rig.diskImage.attachError = UpdateImageError.attachFailed
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.invalidUpdate))
        XCTAssertEqual(rig.log.count("attach"), 1)
        XCTAssertEqual(rig.log.count("detach"), 0, "nothing was attached, so nothing is detached")
        XCTAssertEqual(rig.leftovers(), [])
    }

    func testAStagingFailureDetachesAndRemovesTheStagingFolder() async throws {
        let rig = try InstallerRig(self)
        rig.stager.error = UpdateImageError.stageFailed
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.invalidUpdate))
        XCTAssertEqual(rig.log.count("attach"), 1)
        XCTAssertEqual(rig.log.count("detach"), 1)
        XCTAssertEqual(rig.leftovers(), [], "the half-written staging folder is removed")
        XCTAssertEqual(rig.installedFingerprint, before)
    }

    func testAnInvalidStagedAppIsNotSwappedInAndIsRemoved() async throws {
        let rig = try InstallerRig(self)
        rig.validator.error = UpdateValidationError.signatureInvalid
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.invalidUpdate))
        XCTAssertEqual(rig.log.count("swap"), 0)
        XCTAssertEqual(rig.log.count("relaunch"), 0)
        XCTAssertEqual(rig.log.count("detach"), 1)
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.installedFingerprint, before)
        XCTAssertEqual(rig.validator.validated.count, 1)
        XCTAssertEqual(rig.validator.validated.first?.lastPathComponent, "Isla.app", "it judges the staged copy")
        XCTAssertTrue(rig.validator.validated.first?.path.contains(UpdateInstaller.stagingPrefix) ?? false)
    }

    func testAFailedSwapLeavesTheInstalledAppByteIdenticalAndCleansUp() async throws {
        let rig = try InstallerRig(self)
        rig.swapper.swapper.swap = { _, _ in EACCES }
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.cannotReplace))
        XCTAssertEqual(rig.installedFingerprint, before)
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.log.count("relaunch"), 0)
        XCTAssertEqual(rig.log.count("detach"), 1)
    }

    func testDetachRunsAfterEveryAttachWhateverHappensNext() async throws {
        for scenario in ["stage fails", "validation fails", "swap fails", "success"] {
            let rig = try InstallerRig(self)
            switch scenario {
            case "stage fails": rig.stager.error = UpdateImageError.noApp
            case "validation fails": rig.validator.error = UpdateValidationError.notNewer
            case "swap fails": rig.swapper.swapper.swap = { _, _ in EACCES }
            default: break
            }
            rig.build()
            rig.installer.install(rig.release())
            await rig.finish()
            let log = rig.log.all
            XCTAssertEqual(log.filter { $0 == "attach" }.count, 1, scenario)
            XCTAssertEqual(log.filter { $0 == "detach" }.count, 1, scenario)
            XCTAssertLessThan(log.firstIndex(of: "attach")!, log.firstIndex(of: "detach")!, scenario)
            // The image is detached before the staged copy is judged or swapped in.
            for later in ["validate", "swap", "relaunch"] where log.contains(later) {
                XCTAssertLessThan(log.firstIndex(of: "detach")!, log.firstIndex(of: later)!, "\(scenario): detach before \(later)")
            }
            XCTAssertEqual(rig.leftovers(), [], scenario)
        }
    }

    // MARK: Cancel

    func testCancelDuringTheDownloadReturnsQuietlyAndCleansUp() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.holdImage = true
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.until("the image download to start") { rig.log.count("download \(UpdateInstaller.imageFileName)") == 1 }
        XCTAssertEqual(rig.leftovers().count, 1, "a scratch folder with a partial file exists")
        rig.installer.cancel()
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .idle, "back to the available state, with no error")
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.log.count("verify"), 0)
        XCTAssertEqual(rig.log.count("attach"), 0)
        XCTAssertEqual(rig.installedFingerprint, before)
        // And it can be started again.
        rig.downloader.holdImage = false
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
    }

    func testCancelIsIgnoredOnceTheDownloadIsOver() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        rig.installer.cancel()                       // nothing running
        XCTAssertEqual(rig.installer.phase, .idle)
        rig.installer.install(rig.release())
        await rig.finish()
        rig.installer.cancel()
        XCTAssertEqual(rig.installer.phase, .relaunching)
    }

    // MARK: One at a time, and only when asked

    func testASecondInstallWhileOneRunsIsIgnored() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.holdImage = true
        rig.build()
        rig.installer.install(rig.release())
        await rig.until("the first download") { rig.log.count("download \(UpdateInstaller.imageFileName)") == 1 }
        rig.installer.install(rig.release())
        rig.installer.install(rig.release(version: "0.4.0"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.log.count("download \(UpdateInstaller.signatureFileName)"), 1)
        XCTAssertEqual(rig.installer.release?.version, "0.3.1")
        rig.installer.cancel()
        await rig.finish()
    }

    func testNothingRunsUntilTheButtonIsPressed() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        // A check that finds an update does not touch the installer.
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v0.3.1", "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1",
        ])
        let check = UpdateCheck(
            fetch: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            currentVersion: { "0.3.0" }
        )
        check.check()
        await rig.until("the check") { check.hasUpdate }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.log.all, [])
        XCTAssertEqual(rig.installer.phase, .idle)
        XCTAssertEqual(rig.scratchFolders, [])
    }

    // MARK: Leftovers of a run that never finished

    func testAStagingFolderALostRunLeftBesideTheAppIsSweptAtTheNextInstall() async throws {
        let rig = try InstallerRig(self)
        let stale = rig.apps.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale.appendingPathComponent("Isla.app"), withIntermediateDirectories: true)
        let bystander = rig.apps.appendingPathComponent("Other.app", isDirectory: true)
        let lookalike = rig.apps.appendingPathComponent("Isla-update-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        await rig.until("the sweep") { !FileManager.default.fileExists(atPath: stale.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
    }

    func testAFailedRunCanBeTriedAgain() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.failure = URLError(.timedOut)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.offline))
        rig.downloader.failure = nil
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
        XCTAssertEqual(rig.leftovers(), [])
    }
}

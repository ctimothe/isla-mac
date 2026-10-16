import Foundation
import XCTest
@testable import IslaKit

/// What the review of Update Now asked for: an install that cannot be left half
/// done, a volume that cannot be left mounted or deleted into, a tool that cannot
/// hang it, a relaunch that cannot make Isla vanish, and a failed install that
/// cannot be retried after the world has moved on.
@MainActor
final class UpdateHardeningTests: XCTestCase {

    // MARK: The swap

    /// The fallback `replaceItemAt` can fail with the original moved away; the
    /// installer must still leave an app at the installed path.
    func testAFailedFallbackSwapLeavesTheInstalledAppInPlace() async throws {
        let rig = try InstallerRig(self)
        rig.build()
        let hidden = rig.root.appendingPathComponent("moved-aside.app")
        rig.swapper.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.swapper.replace = { installed, _ in
            try FileManager.default.moveItem(at: installed, to: hidden)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [FileManagerSwapper.originalItemLocationKey: hidden])
        }
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.cannotReplace))
        XCTAssertEqual(rig.installedFingerprint, before, "the original is back, byte for byte")
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.log.count("relaunch"), 0)
    }

    // MARK: The relaunch

    func testARelaunchThatCannotStartSaysToRestartAndDoesNotQuit() async throws {
        let rig = try InstallerRig(self)
        rig.relauncher.succeeds = false
        rig.build()
        rig.installer.install(rig.release())
        await rig.until("the restart state") { rig.installer.phase == .restartNeeded }
        XCTAssertEqual(rig.relauncher.calls.count, 1)
        XCTAssertEqual(try String(contentsOf: rig.installed.appendingPathComponent("marker.txt"), encoding: .utf8), "new",
                       "the update is installed")
        XCTAssertEqual(rig.leftovers(), [])
        // Final: nothing starts another install, and a check does not end it.
        rig.installer.install(rig.release(version: "0.4.0"))
        rig.installer.reset()
        rig.installer.settle(with: .upToDate(version: "0.3.1"))
        XCTAssertEqual(rig.installer.phase, .restartNeeded)
        XCTAssertEqual(rig.log.count("download \(UpdateInstaller.signatureFileName)"), 1)
    }

    // MARK: A volume that will not detach

    func testAnImageThatWillNotDetachStopsBeforeTheSwapAndLeavesItsFolderAlone() async throws {
        let rig = try InstallerRig(self)
        rig.diskImage.detaches = false
        // A volume is "still mounted" in whichever scratch folder was made.
        var scratchSeen: [URL] = []
        rig.containsMount = { url in
            let isScratch = url.path.hasPrefix(rig.scratchRoot.path) && url.deletingLastPathComponent() == rig.scratchRoot
            if isScratch { scratchSeen.append(url) }
            return isScratch
        }
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()

        XCTAssertEqual(rig.installer.phase, .failed(.cannotOpen))
        XCTAssertEqual(rig.log.count("detach"), 1)
        XCTAssertEqual(rig.log.count("validate"), 0)
        XCTAssertEqual(rig.log.count("swap"), 0)
        XCTAssertEqual(rig.log.count("relaunch"), 0)
        XCTAssertEqual(rig.installedFingerprint, before)
        let kept = try XCTUnwrap(rig.scratchFolders.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("mount").path),
                      "nothing was deleted into the mounted folder")
        XCTAssertTrue(scratchSeen.contains(kept))
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: rig.apps.path)) ?? []
        XCTAssertEqual(staging.filter { $0.hasPrefix(UpdateInstaller.stagingPrefix) }, [], "the staging folder is still removed")
    }

    func testAFailedStageAndAFailedDetachTogetherAreCannotOpen() async throws {
        let rig = try InstallerRig(self)
        rig.stager.error = UpdateImageError.stageFailed
        rig.diskImage.detaches = false
        rig.containsMount = { $0.deletingLastPathComponent() == rig.scratchRoot }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.cannotOpen), "the volume still being there is what the person must hear")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.scratchFolders.first).path))
    }

    func testAnAttachThatLeftAVolumeItCouldNotDetachKeepsTheFolder() async throws {
        let rig = try InstallerRig(self)
        rig.diskImage.attachError = UpdateImageError.stillAttached
        rig.containsMount = { $0.deletingLastPathComponent() == rig.scratchRoot }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.cannotOpen))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.scratchFolders.first).path))
        XCTAssertEqual(rig.log.count("detach"), 0, "the disk image collaborator already tried")
    }

    func testAFolderWithNoVolumeInItIsRemovedAsBefore() async throws {
        let rig = try InstallerRig(self)
        rig.stager.error = UpdateImageError.stageFailed
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.leftovers(), [])
    }

    // MARK: A tool that hangs

    func testAHungStepEndsInFailureAtTheCeilingAndCleansUp() async throws {
        let rig = try InstallerRig(self)
        rig.stager.hangs = true
        rig.installTimeout = 0.3
        rig.build()
        let before = rig.installedFingerprint
        let start = Date()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(rig.installer.phase, .failed(.cannotOpen), "not a cancel, and not a card that never changes")
        XCTAssertEqual(rig.log.count("attach"), 1)
        XCTAssertEqual(rig.log.count("detach"), 1, "the image that was mounted is detached even though the task was cancelled")
        XCTAssertEqual(rig.log.count("swap"), 0)
        XCTAssertEqual(rig.installedFingerprint, before)
        XCTAssertEqual(rig.leftovers(), [])
        // Try Again works.
        rig.stager.hangs = false
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
    }

    func testTheCeilingDoesNotTouchAnInstallThatFinishesInTime() async throws {
        let rig = try InstallerRig(self)
        rig.installTimeout = 5
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.log.count("relaunch"), 1)
        XCTAssertEqual(rig.installer.phase, .relaunching)
    }

    // MARK: Who may replace the app

    func testAnAppAnotherAccountOwnsOffersOnlyTheDownload() async throws {
        let rig = try InstallerRig(self)
        rig.canReplace = { _ in false }
        rig.build()
        XCTAssertEqual(rig.installer.manualReason(for: rig.release()), .notOwned)
        XCTAssertTrue(UpdateInstaller.ManualReason.notOwned.isLocation)
        rig.installer.install(rig.release())
        XCTAssertEqual(rig.installer.phase, .manualOnly(.notOwned))
        XCTAssertEqual(rig.log.all, [])
    }

    func testAnAppThisUserOwnsCanBeReplaced() throws {
        let rig = try InstallerRig(self)
        XCTAssertTrue(UpdateInstaller.currentUserCanReplace(rig.installed), "a folder this test just made")
        XCTAssertFalse(UpdateInstaller.currentUserCanReplace(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertFalse(UpdateInstaller.currentUserCanReplace(rig.root.appendingPathComponent("missing.app")))
    }

    func testTheRealMountCheckSeesNoVolumeInAnOrdinaryFolder() throws {
        let rig = try InstallerRig(self)
        XCTAssertFalse(UpdateInstaller.directoryContainsMount(rig.root))
        XCTAssertFalse(UpdateInstaller.directoryContainsMount(rig.root.appendingPathComponent("nope")))
    }

    // MARK: Identity

    func testAnUpdateSignedByAnotherIdentityIsManualAndInstallsNothing() async throws {
        let rig = try InstallerRig(self)
        rig.validator.error = UpdateValidationError.identityChanged
        rig.build()
        let before = rig.installedFingerprint
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .manualOnly(.identityChanged))
        XCTAssertFalse(UpdateInstaller.ManualReason.identityChanged.isLocation, "it reads 'download page', not 'this location'")
        XCTAssertEqual(rig.log.count("swap"), 0)
        XCTAssertEqual(rig.log.count("detach"), 1)
        XCTAssertEqual(rig.installedFingerprint, before)
        XCTAssertEqual(rig.leftovers(), [])
    }

    // MARK: A stale failure

    private func failedRig() async throws -> InstallerRig {
        let rig = try InstallerRig(self)
        rig.downloader.failure = URLError(.timedOut)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .failed(.offline))
        return rig
    }

    func testACheckThatFindsIslaUpToDateEndsAFailedInstall() async throws {
        let rig = try await failedRig()
        rig.installer.settle(with: .checking)
        XCTAssertEqual(rig.installer.phase, .failed(.offline), "an in-flight check changes nothing")
        rig.installer.settle(with: .failed(.offline))
        XCTAssertEqual(rig.installer.phase, .failed(.offline))
        rig.installer.settle(with: .upToDate(version: "0.3.1"))
        XCTAssertEqual(rig.installer.phase, .idle)
    }

    func testACheckThatFindsADifferentReleaseEndsIt_AndTheSameOneKeepsIt() async throws {
        let rig = try await failedRig()
        rig.installer.settle(with: .available(rig.release()))
        XCTAssertEqual(rig.installer.phase, .failed(.offline), "the release that failed is still the one on offer")
        rig.installer.settle(with: .available(rig.release(version: "0.4.0")))
        XCTAssertEqual(rig.installer.phase, .idle, "Try Again must not reinstall a release that is no longer the one on offer")
    }

    func testAManualVerdictIsEndedTheSameWay() async throws {
        let rig = try InstallerRig(self)
        rig.publicKey = nil
        rig.build()
        rig.installer.install(rig.release())
        XCTAssertEqual(rig.installer.phase, .manualOnly(.noPublicKey))
        rig.installer.settle(with: .available(rig.release()))
        XCTAssertEqual(rig.installer.phase, .manualOnly(.noPublicKey))
        rig.installer.settle(with: .upToDate(version: "0.3.1"))
        XCTAssertEqual(rig.installer.phase, .idle)
    }

    func testAnInstallUnderWayIsNotEndedByACheck() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.holdImage = true
        rig.build()
        rig.installer.install(rig.release())
        await rig.until("the download") { rig.log.count("download \(UpdateInstaller.imageFileName)") == 1 }
        rig.installer.settle(with: .upToDate(version: "0.3.1"))
        rig.installer.settle(with: .available(rig.release(version: "0.4.0")))
        if case .downloading = rig.installer.phase {} else { XCTFail("\(rig.installer.phase)") }
        rig.installer.cancel()
        await rig.finish()
    }

    /// The wiring: a real `UpdateCheck` finishing up to date ends the failure.
    func testTheInstallerFollowsTheCheck() async throws {
        let rig = try await failedRig()
        let check = UpdateCheck(
            fetch: { request in
                let data = Data(#"{"tag_name":"v0.3.0","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v0.3.0"}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            currentVersion: { "0.3.1" }
        )
        rig.installer.observe(check)
        check.check()
        await rig.until("the failure to end") { rig.installer.phase == .idle }
    }

    // MARK: Leftovers

    private func staging(_ folder: URL, name: String = UUID().uuidString) throws -> URL {
        let url = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Isla.app"), withIntermediateDirectories: true)
        return url
    }

    func testOnlyAnExactStagingFolderIsSwept() throws {
        let folder = try UpdateTestSupport.folder(self)
        let mine = try staging(folder)
        let lower = try staging(folder, name: UUID().uuidString.lowercased())
        let notUUID = try staging(folder, name: "OLD")
        let almost = try staging(folder, name: UUID().uuidString + "x")
        let prefixed = folder.appendingPathComponent("Isla-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: prefixed, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: file)
        let target = folder.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let bystander = folder.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)

        UpdateInstaller.sweepStaleStaging(in: folder)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: mine.path))
        XCTAssertFalse(fm.fileExists(atPath: lower.path), "a UUID in any case")
        for kept in [notUUID, almost, prefixed, file, bystander, target] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "a link by that name is left, and what it points at")
    }

    func testAFolderAnotherUserOwnsIsNotSwept() throws {
        let folder = try UpdateTestSupport.folder(self)
        let theirs = try staging(folder)
        let mine = try staging(folder)
        UpdateInstaller.sweepStaleStaging(in: folder, ownerID: { $0 == theirs ? 0 : getuid() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
    }

    func testTheInstallUnderWayIsNotSwept() throws {
        let folder = try UpdateTestSupport.folder(self)
        let current = try staging(folder)
        let stale = try staging(folder)
        UpdateInstaller.sweepStaleStaging(in: folder, except: current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testTheLaunchSweepCleansBesideTheInstalledApp() async throws {
        let rig = try InstallerRig(self)
        let stale = try staging(rig.apps)
        var environment = UpdateEnvironment.neverInstalls
        environment.installedURL = rig.installed
        UpdateInstaller.sweepAtLaunch(environment: environment)
        await rig.until("the launch sweep") { !FileManager.default.fileExists(atPath: stale.path) }
    }

    func testTheLaunchSweepDoesNothingForAnAppThatIsNotInstalled() throws {
        let folder = try UpdateTestSupport.folder(self)
        let stale = try staging(folder)
        var environment = UpdateEnvironment.neverInstalls
        environment.installedURL = folder.appendingPathComponent("Isla")            // not a bundle
        UpdateInstaller.sweepAtLaunch(environment: environment)
        environment.installedURL = URL(fileURLWithPath: "/Volumes/Isla/Isla.app")
        UpdateInstaller.sweepAtLaunch(environment: environment)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }
}

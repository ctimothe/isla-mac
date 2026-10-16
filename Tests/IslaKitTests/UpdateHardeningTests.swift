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

    /// The ceiling is one: at it, Try Again is on the card within a few seconds
    /// even though a step behind it is not listening and is still running.
    func testTheCeilingEndsTheCardEvenWhileAStepIsStillRunning() async throws {
        let rig = try InstallerRig(self)
        rig.stager.deafSeconds = 1.5
        rig.installTimeout = 0.3
        rig.build()
        let before = rig.installedFingerprint
        let start = Date()
        rig.installer.install(rig.release())
        await rig.until("the failure at the ceiling") { rig.installer.phase == .failed(.cannotOpen) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.2, "ceiling plus a moment, not when the step comes back")

        // Try Again at once, while the old run is still inside its step.
        rig.stager.deafSeconds = 0
        rig.installer.install(rig.release())
        await rig.until("the new run to finish") { rig.log.count("relaunch") == 1 }
        // The old run now comes back, finds it is not the current one, cleans up
        // and leaves the new run's card alone and the swap undone.
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(rig.installer.phase, .relaunching, "the old run did not overwrite the new run's phase")
        XCTAssertEqual(rig.log.count("swap"), 1, "only the new run swapped; the old one stopped at the ceiling")
        XCTAssertNotEqual(rig.installedFingerprint, before)
        XCTAssertEqual(rig.leftovers(), [])
    }

    /// After a failure that followed a mount, the image is looked up once more
    /// by its file before the folder goes; if it will not let go, the folder stays.
    func testALateMountIsLookedForBeforeTheFolderIsDeleted() async throws {
        let rig = try InstallerRig(self)
        rig.validator.error = UpdateValidationError.signatureInvalid
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.diskImage.cleanedUp.count, 1)
        XCTAssertEqual(rig.diskImage.cleanedUp.first?.lastPathComponent, UpdateInstaller.imageFileName)
        XCTAssertEqual(rig.leftovers(), [])
    }

    func testAnImageThatMountedLateAndWillNotDetachKeepsTheFolder() async throws {
        let rig = try InstallerRig(self)
        rig.stager.error = UpdateImageError.stageFailed
        rig.diskImage.cleansUp = false
        rig.containsMount = { $0.deletingLastPathComponent() == rig.scratchRoot }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.diskImage.cleanedUp.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.scratchFolders.first).path))
    }

    func testNothingIsLookedForWhenNothingWasEverAttached() async throws {
        let rig = try InstallerRig(self)
        rig.downloader.failure = URLError(.timedOut)
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.diskImage.cleanedUp, [])
        let verifyFails = try InstallerRig(self)
        verifyFails.verifier.valid = false
        verifyFails.build()
        verifyFails.installer.install(verifyFails.release())
        await verifyFails.finish()
        XCTAssertEqual(verifyFails.diskImage.cleanedUp, [], "a bad signature never reached the mount")
    }

    // MARK: A sweep never meets an install

    /// A sweep that lands while this install is staging, however it got there,
    /// must not touch the folder: it is the app that is about to be swapped in.
    func testASweepThatLandsDuringStagingLeavesTheInstallsFolderAlone() async throws {
        let rig = try InstallerRig(self)
        let apps = rig.apps
        let activity = rig.activity
        let seen = Seen()
        rig.stager.afterStaging = {
            UpdateInstaller.sweepStaleStaging(in: apps, activity: activity)     // no `except:`, the worst case
            let names = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
            seen.set(names.filter { $0.hasPrefix(UpdateInstaller.stagingPrefix) }.count)
        }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(seen.value, 1, "the staging folder was still there after the sweep")
        XCTAssertEqual(rig.installer.phase, .relaunching)
        XCTAssertEqual(try String(contentsOf: rig.installed.appendingPathComponent("marker.txt"), encoding: .utf8), "new")
    }

    func testASweepDuringValidationLeavesTheStagedCopyAlone() async throws {
        let rig = try InstallerRig(self)
        let apps = rig.apps
        let activity = rig.activity
        let seen = Seen()
        rig.validator.onValidate = { staged in
            UpdateInstaller.sweepStaleStaging(in: apps, activity: activity)
            seen.set(FileManager.default.fileExists(atPath: staged.path) ? 1 : 0)
        }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(seen.value, 1, "the staged copy survived the sweep")
        XCTAssertEqual(rig.log.count("relaunch"), 1)
    }

    func testTheGuardIsReleasedWhenTheInstallEndsHowEverItEnds() async throws {
        for scenario in ["success", "stage fails", "validation fails", "swap fails"] {
            let rig = try InstallerRig(self)
            switch scenario {
            case "stage fails": rig.stager.error = UpdateImageError.stageFailed
            case "validation fails": rig.validator.error = UpdateValidationError.notNewer
            case "swap fails": rig.swapper.swapper.swap = { _, _ in EACCES }
            default: break
            }
            rig.build()
            rig.installer.install(rig.release())
            await rig.finish()
            await rig.until("the guard to be let go: \(scenario)") { !rig.activity.isActive }
        }
    }

    func testASweepWithAnInstallStagingTouchesNothingAndOneAfterwardsDoes() throws {
        let folder = try UpdateTestSupport.folder(self)
        let stale = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let activity = UpdateInstaller.StagingActivity()
        activity.begin()
        UpdateInstaller.sweepStaleStaging(in: folder, activity: activity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "refused while an install is staging")
        activity.end()
        UpdateInstaller.sweepStaleStaging(in: folder, activity: activity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testASweepThatStartsFreeStopsWhenAnInstallBeginsMidWalk() throws {
        let folder = try UpdateTestSupport.folder(self)
        var folders: [URL] = []
        for _ in 0..<5 {
            let url = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folders.append(url)
        }
        var asked = 0
        let activity = UpdateInstaller.StagingActivity()
        UpdateInstaller.sweepStaleStaging(in: folder, ownerID: { _ in
            asked += 1
            if asked == 2 { activity.begin() }
            return getuid()
        }, activity: activity)
        let left = folders.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        XCTAssertGreaterThanOrEqual(left, 3, "once an install began the walk removed nothing more")
    }

    /// The guard is let go after the cleanup, so the cleanup finishes with no
    /// sweep able to meet it.
    func testTheGuardIsStillHeldWhileTheCleanupRuns() async throws {
        let rig = try InstallerRig(self)
        let activity = rig.activity
        let held = Seen()
        rig.stager.error = UpdateImageError.stageFailed
        rig.containsMount = { _ in
            // Asked by the cleanup for each folder it is about to remove.
            held.set(activity.isActive ? 1 : 0)
            return false
        }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(held.value, 1, "the guard was still held when the cleanup ran")
        await rig.until("the guard to be let go") { !rig.activity.isActive }
    }

    // MARK: Never the only good copy

    /// The worst swap: the fallback moves the original aside and fails, putting
    /// it back fails, and the staged copy cannot be moved in either. The staging
    /// folder is then all there is of Isla, and nothing may delete it.
    func testTheStagedCopyIsKeptWhenNothingCouldBePutInPlace() async throws {
        let rig = try InstallerRig(self)
        let hidden = rig.root.appendingPathComponent("moved-aside.app")
        rig.swapper.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.swapper.replace = { installed, _ in
            try FileManager.default.moveItem(at: installed, to: hidden)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [FileManagerSwapper.originalItemLocationKey: hidden])
        }
        rig.swapper.swapper.move = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        await rig.until("the guard to be let go") { !rig.activity.isActive }
        XCTAssertEqual(rig.installer.phase, .failed(.cannotReplace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.installed.path))
        let beside = (try? FileManager.default.contentsOfDirectory(atPath: rig.apps.path)) ?? []
        let staging = try XCTUnwrap(beside.first { $0.hasPrefix(UpdateInstaller.stagingPrefix) }, "the staging folder is still there: \(beside)")
        XCTAssertEqual(
            try String(contentsOf: rig.apps.appendingPathComponent(staging).appendingPathComponent("Isla.app/marker.txt"), encoding: .utf8),
            "new", "with the new app in it"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path), "and the original, where it was moved")
        XCTAssertEqual(rig.log.count("relaunch"), 0)
    }

    func testTheStagedCopyTakesTheEmptyPathAndTheInstallSucceeds() async throws {
        let rig = try InstallerRig(self)
        let hidden = rig.root.appendingPathComponent("moved-aside.app")
        let moves = Seen()
        rig.swapper.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.swapper.replace = { installed, _ in
            try FileManager.default.moveItem(at: installed, to: hidden)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [FileManagerSwapper.originalItemLocationKey: hidden])
        }
        let real = rig.swapper.swapper.move
        rig.swapper.swapper.move = { from, to in
            moves.set(moves.value + 2)            // -1 -> 1 on the first call, 3 on the second
            if moves.value == 1 { throw CocoaError(.fileWriteNoPermission) }
            try real(from, to)
        }
        rig.build()
        rig.installer.install(rig.release())
        await rig.finish()
        XCTAssertEqual(rig.installer.phase, .relaunching)
        XCTAssertEqual(try String(contentsOf: rig.installed.appendingPathComponent("marker.txt"), encoding: .utf8), "new")
        await rig.until("the cleanup") { rig.leftovers().isEmpty }
    }

    func testNoSweepRemovesAStagingFolderWhileTheInstalledPathIsMissing() throws {
        let folder = try UpdateTestSupport.folder(self)
        let installed = folder.appendingPathComponent("Isla.app", isDirectory: true)
        let staging = folder.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Isla.app"), withIntermediateDirectories: true)
        UpdateInstaller.sweepStaleStaging(in: folder, installed: installed, activity: UpdateInstaller.StagingActivity())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "nothing is at the installed path")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        UpdateInstaller.sweepStaleStaging(in: folder, installed: installed, activity: UpdateInstaller.StagingActivity())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "once there is an app again it is just stale")
    }

    func testTheLaunchSweepAlsoWaitsForTheInstalledApp() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let apps = folder.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let staging = apps.appendingPathComponent("\(UpdateInstaller.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var environment = UpdateEnvironment.neverInstalls
        environment.installedURL = apps.appendingPathComponent("Isla.app")       // missing
        UpdateInstaller.sweepAtLaunch(environment: environment)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: A run ended at its ceiling publishes nothing more

    func testARunEndedAtItsCeilingCannotBringBackACardThatWasMovedOn() async throws {
        let rig = try InstallerRig(self)
        rig.stager.deafSeconds = 1.0
        rig.installTimeout = 0.2
        rig.build()
        rig.installer.install(rig.release())
        await rig.until("the ceiling") { rig.installer.phase == .failed(.cannotOpen) }
        rig.installer.settle(with: .upToDate(version: "0.3.1"))
        XCTAssertEqual(rig.installer.phase, .idle)
        // The old run now comes back from its step, throws, and cleans up.
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(rig.installer.phase, .idle, "its catch published nothing")
        XCTAssertEqual(rig.leftovers(), [])
        XCTAssertEqual(rig.log.count("swap"), 0)
    }

    func testARunEndedAtItsCeilingCannotBringBackADifferentReleaseEither() async throws {
        let rig = try InstallerRig(self)
        rig.stager.deafSeconds = 1.0
        rig.installTimeout = 0.2
        rig.build()
        rig.installer.install(rig.release())
        await rig.until("the ceiling") { rig.installer.phase == .failed(.cannotOpen) }
        rig.installer.settle(with: .available(rig.release(version: "0.4.0")))
        XCTAssertEqual(rig.installer.phase, .idle)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(rig.installer.phase, .idle)
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
        let newline = try staging(folder, name: UUID().uuidString + "\n")
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
        for kept in [notUUID, newline, almost, prefixed, file, bystander, target] {
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

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = -1
    func set(_ value: Int) { lock.withLock { stored = value } }
    var value: Int { lock.withLock { stored } }
}

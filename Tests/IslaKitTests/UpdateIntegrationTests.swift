import Foundation
import XCTest
@testable import IslaKit

/// The whole of Update Now with every real collaborator — the real downloader,
/// verifier, `hdiutil`, `ditto`, validator and swapper — against tiny ad-hoc
/// signed apps in a folder of the test's own.
///
/// **Opt-in.** Skipped unless `ISLA_UPDATE_INTEGRATION=1`, and never part of
/// `./scripts/check`: it builds a disk image and mounts it, which a gate should
/// not do. It never touches `/Applications`, never relaunches anything (the
/// relauncher is a fake) and never reaches the network: the one thing replaced
/// is the wire, a `URLProtocol` that answers the release's two URLs from files in
/// the test folder, so the real downloader still runs its delegate, its progress,
/// its status check and its move.
///
///     ISLA_UPDATE_INTEGRATION=1 swift test --disable-sandbox --filter UpdateIntegrationTests
@MainActor
final class UpdateIntegrationTests: XCTestCase {
    private var folder: URL!
    private var apps: URL!
    private var installed: URL!
    private let key = UpdateTestSupport.Key()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ISLA_UPDATE_INTEGRATION"] == "1",
                          "set ISLA_UPDATE_INTEGRATION=1 to run the update integration test")
        folder = try UpdateTestSupport.folder(self)
        apps = folder.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        installed = try UpdateTestSupport.tinyApp(in: apps, version: "1.0", build: "1", marker: "installed 1.0")
    }

    override func tearDown() async throws {
        StubGitHub.clear()
        // A failed run must not leave a volume mounted from the test folder.
        for mount in mountedImages() { UpdateTestSupport.run("/usr/bin/hdiutil", ["detach", "-force", mount]) }
    }

    // MARK: Fixtures

    private struct Fixture {
        let release: UpdateCheck.Release
        let image: URL
    }

    /// A DMG holding a 1.1 app, a link to /Applications beside it (the usual
    /// layout, and a thing the stager must ignore), its signature and a release
    /// naming both the way Isla's own release does.
    private func makeRelease(tamper: Bool = false) throws -> Fixture {
        let source = folder.appendingPathComponent("Src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try UpdateTestSupport.tinyApp(in: source, version: "1.1", build: "2", marker: "new 1.1")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = folder.appendingPathComponent("Isla-1.1.dmg")
        let made = UpdateTestSupport.run("/usr/bin/hdiutil", [
            "create", "-srcfolder", source.path, "-volname", "Isla", "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path,
        ])
        XCTAssertEqual(made.status, 0, made.output)
        var bytes = try Data(contentsOf: dmg)
        let signature = key.sign(bytes)
        if tamper { bytes[bytes.count / 2] ^= 0xFF }
        let served = bytes
        let sig = Data((signature + "\n").utf8)

        let base = "https://github.com/ctimothe/isla-mac/releases/download/v1.1/"
        StubGitHub.serve(URL(string: base + "Isla-1.1.dmg")!, served)
        StubGitHub.serve(URL(string: base + "Isla-1.1.dmg.sig")!, sig)
        let release = UpdateCheck.Release(
            version: "1.1", page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v1.1")!,
            notes: "Integration.",
            dmg: .init(name: "Isla-1.1.dmg", url: URL(string: base + "Isla-1.1.dmg")!, size: Int64(served.count)),
            signature: .init(name: "Isla-1.1.dmg.sig", url: URL(string: base + "Isla-1.1.dmg.sig")!, size: Int64(sig.count))
        )
        return Fixture(release: release, image: dmg)
    }

    /// A disk image with TWO volumes, the first holding a 1.1 app: attaching it
    /// mounts both. Made by partitioning a blank image (`diskutil`), copying the
    /// app into the first volume and detaching.
    private func makeTwoVolumeRelease() throws -> Fixture {
        let blank = folder.appendingPathComponent("Isla-1.1.dmg")
        let made = UpdateTestSupport.run("/usr/bin/hdiutil", ["create", "-size", "40m", "-layout", "GPTSPUD", "-fs", "HFS+", "-volname", "Seed", "-ov", blank.path])
        XCTAssertEqual(made.status, 0, made.output)
        let attach = UpdateTestSupport.run("/usr/bin/hdiutil", ["attach", "-nomount", "-plist", blank.path])
        let device = try XCTUnwrap(attach.output.range(of: #"/dev/disk\d+"#, options: .regularExpression).map { String(attach.output[$0]) }, attach.output)
        defer { UpdateTestSupport.run("/usr/bin/hdiutil", ["detach", "-force", device]) }
        let tag = UUID().uuidString.prefix(8)
        let first = "IslaLabOne\(tag)", second = "IslaLabTwo\(tag)"
        let split = UpdateTestSupport.run("/usr/sbin/diskutil", ["partitionDisk", device, "GPT", "HFS+", first, "50%", "HFS+", second, "50%"])
        XCTAssertEqual(split.status, 0, split.output)
        let source = folder.appendingPathComponent("Src2", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let app = try UpdateTestSupport.tinyApp(in: source, version: "1.1", build: "2", marker: "new 1.1")
        let copied = UpdateTestSupport.run("/usr/bin/ditto", [app.path, "/Volumes/\(first)/Isla.app"])
        XCTAssertEqual(copied.status, 0, copied.output)
        let bytes: Data = try {
            UpdateTestSupport.run("/usr/bin/hdiutil", ["detach", "-force", device])
            return try Data(contentsOf: blank)
        }()
        return try serve(bytes, image: blank)
    }

    private func serve(_ bytes: Data, image: URL) throws -> Fixture {
        let signature = key.sign(bytes)
        let sig = Data((signature + "\n").utf8)
        let base = "https://github.com/ctimothe/isla-mac/releases/download/v1.1/"
        StubGitHub.serve(URL(string: base + "Isla-1.1.dmg")!, bytes)
        StubGitHub.serve(URL(string: base + "Isla-1.1.dmg.sig")!, sig)
        let release = UpdateCheck.Release(
            version: "1.1", page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v1.1")!,
            notes: "Integration.",
            dmg: .init(name: "Isla-1.1.dmg", url: URL(string: base + "Isla-1.1.dmg")!, size: Int64(bytes.count)),
            signature: .init(name: "Isla-1.1.dmg.sig", url: URL(string: base + "Isla-1.1.dmg.sig")!, size: Int64(sig.count))
        )
        return Fixture(release: release, image: image)
    }

    /// The validator a running app of this identity would build: the real
    /// identity logic over the installed tiny app's own code, which is ad-hoc, so
    /// any valid signature is accepted. (The test host is not ad-hoc, so
    /// `running()` itself would be the wrong stand-in here.)
    private func installedValidator() -> BundleUpdateValidator {
        var code: SecStaticCode?
        SecStaticCodeCreateWithPath(installed as CFURL, [], &code)
        return BundleUpdateValidator(
            runningVersion: "1.0", runningBuild: "1",
            satisfiesRunningIdentity: BundleUpdateValidator.identityCheck(for: code!)
        )
    }

    private func makeInstaller(relauncher: FakeRelauncher, scratch: ScratchLog) -> UpdateInstaller {
        var environment = UpdateEnvironment.live()
        environment.installedURL = installed
        environment.publicKey = key.publicBase64
        let live = environment.makeScratchFolder
        environment.makeScratchFolder = {
            let folder = try live()
            scratch.note(folder)
            return folder
        }
        var downloader = URLSessionUpdateDownloader()
        downloader.makeSession = { PrivateNetwork.makeSession(delegate: $0, protocolClasses: [StubGitHub.self]) }
        return UpdateInstaller(
            environment: environment, downloader: downloader,
            validator: installedValidator(),
            relauncher: relauncher
        )
    }

    final class ScratchLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var folders: [URL] = []
        func note(_ url: URL) { lock.lock(); folders.append(url); lock.unlock() }
    }

    private func wait(_ installer: UpdateInstaller, until done: () -> Bool) async {
        for _ in 0..<4000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), "timed out in \(installer.phase)")
    }

    /// Mount points of any attached image whose file lives in this test's folder.
    private func mountedImages() -> [String] {
        guard let folder else { return [] }
        let info = UpdateTestSupport.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard let data = info.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }
        var mounts: [String] = []
        for image in images {
            let path = (image["image-path"] as? String) ?? ""
            guard path.hasPrefix(folder.path) || path.hasPrefix("/private" + folder.path) else { continue }
            for entity in (image["system-entities"] as? [[String: Any]]) ?? [] {
                if let mount = entity["mount-point"] as? String { mounts.append(mount) }
            }
            if mounts.isEmpty, let dev = (image["system-entities"] as? [[String: Any]])?.first?["dev-entry"] as? String { mounts.append(dev) }
        }
        return mounts
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    // MARK: The cases

    func testARealUpdateReplacesTheInstalledAppAndLeavesNothingBehind() async throws {
        let fixture = try makeRelease()
        let relauncher = FakeRelauncher(log: Recorder())
        let scratch = ScratchLog()
        let installer = makeInstaller(relauncher: relauncher, scratch: scratch)
        XCTAssertNil(installer.manualReason(for: fixture.release))
        installer.install(fixture.release)
        await wait(installer) { !relauncher.calls.isEmpty || { if case .failed = installer.phase { return true } else { return false } }() }

        XCTAssertEqual(installer.phase, .relaunching)
        XCTAssertEqual(relauncher.calls.count, 1)
        XCTAssertEqual(relauncher.calls.first?.installed, installed)
        XCTAssertEqual(version(of: installed), "1.1", "the installed app is the update")
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8), "new 1.1")
        let verify = UpdateTestSupport.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", installed.path])
        XCTAssertEqual(verify.status, 0, "the swapped-in app is intact: \(verify.output)")
        // Nothing of the run is left.
        let beside = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(beside, ["Isla.app"], "no staging folder, no backup: \(beside)")
        XCTAssertFalse(scratch.folders.isEmpty)
        for folder in scratch.folders { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(folder.path) was removed") }
        XCTAssertEqual(mountedImages(), [], "no volume stays mounted")
    }

    /// The rehearsal, end to end over real files: a release.json and the image
    /// and signature in a folder, found by a real check, downloaded by the real
    /// downloader's file path, and installed by everything else unchanged.
    func testARehearsalInstallsFromALocalFolder() async throws {
        _ = try makeRelease()
        let dmg = folder.appendingPathComponent("Isla-1.1.dmg")
        let bytes = try Data(contentsOf: dmg)
        let rehearsal = folder.appendingPathComponent("Rehearsal", isDirectory: true)
        try FileManager.default.createDirectory(at: rehearsal, withIntermediateDirectories: true)
        let folderURL = rehearsal.resolvingSymlinksInPath()
        let sig = Data((key.sign(bytes) + "\n").utf8)
        try bytes.write(to: folderURL.appendingPathComponent("Isla-1.1.dmg"))
        try sig.write(to: folderURL.appendingPathComponent("Isla-1.1.dmg.sig"))
        let object: [String: Any] = [
            "tag_name": "v1.1", "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v1.1",
            "body": "Rehearsal build made by Scripts/rehearse-update.sh.",
            "assets": [
                ["name": "Isla-1.1.dmg", "size": bytes.count, "browser_download_url": "file://\(folderURL.path)/Isla-1.1.dmg"],
                ["name": "Isla-1.1.dmg.sig", "size": sig.count, "browser_download_url": "file://\(folderURL.path)/Isla-1.1.dmg.sig"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: folderURL.appendingPathComponent("release.json"))
        StubGitHub.clear()          // nothing may be fetched: the wire is empty

        let check = UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }, currentVersion: { "1.0" }, rehearsal: folderURL)
        check.check()
        await wait(UpdateInstaller(environment: .neverInstalls)) { check.lastAvailable != nil }
        let release = try XCTUnwrap(check.lastAvailable)

        var environment = UpdateEnvironment.live()
        environment.installedURL = installed
        environment.publicKey = key.publicBase64
        environment.rehearsal = folderURL
        let relauncher = FakeRelauncher(log: Recorder())
        let installer = UpdateInstaller(
            environment: environment,
            validator: installedValidator(),
            relauncher: relauncher
        )
        XCTAssertNil(installer.manualReason(for: release))
        installer.install(release)
        await wait(installer) { !relauncher.calls.isEmpty || { if case .failed = installer.phase { return true } else { return false } }() }
        XCTAssertEqual(installer.phase, .relaunching)
        XCTAssertEqual(version(of: installed), "1.1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Isla.app"])
        XCTAssertEqual(mountedImages(), [])
    }

    /// An image that mounts two volumes is not an Isla update: both are detached,
    /// nothing is copied, the app is untouched and no volume is left behind.
    func testAnImageWithTwoVolumesIsRefusedAndBothAreDetached() async throws {
        let fixture = try makeTwoVolumeRelease()
        XCTAssertLessThanOrEqual(fixture.release.dmg?.size ?? .max, 100 * 1024 * 1024)
        // First, that the image really does mount two volumes, and that the real
        // collaborator says so and lets go of both.
        let probe = folder.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        do {
            _ = try await HdiutilDiskImage().attach(fixture.image, scratch: probe)
            XCTFail("a two-volume image must not attach as one")
        } catch {
            XCTAssertEqual(error as? UpdateImageError, .oneVolumeExpected)
        }
        XCTAssertEqual(mountedImages(), [], "the probe detached both")
        let relauncher = FakeRelauncher(log: Recorder())
        let scratch = ScratchLog()
        let installer = makeInstaller(relauncher: relauncher, scratch: scratch)
        let before = UpdateTestSupport.fingerprint(of: installed)
        installer.install(fixture.release)
        await wait(installer) { if case .failed = installer.phase { return true } else { return false } }

        XCTAssertEqual(installer.phase, .failed(.invalidUpdate))
        XCTAssertTrue(relauncher.calls.isEmpty)
        XCTAssertEqual(UpdateTestSupport.fingerprint(of: installed), before)
        // The card moves to the failure first and the last of the cleanup (the
        // lookup for a late mount, then the folders) finishes just behind it.
        await wait(installer) { scratch.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Isla.app"])
        for folder in scratch.folders { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is left in \(folder.path)") }
        XCTAssertEqual(mountedImages(), [], "neither volume stays mounted")
    }

    func testATamperedImageIsRefusedBeforeItIsEverMounted() async throws {
        let fixture = try makeRelease(tamper: true)
        let relauncher = FakeRelauncher(log: Recorder())
        let scratch = ScratchLog()
        let installer = makeInstaller(relauncher: relauncher, scratch: scratch)
        let before = UpdateTestSupport.fingerprint(of: installed)
        installer.install(fixture.release)
        await wait(installer) { if case .failed = installer.phase { return true } else { return false } }

        XCTAssertEqual(installer.phase, .failed(.signature))
        XCTAssertTrue(relauncher.calls.isEmpty)
        XCTAssertEqual(version(of: installed), "1.0")
        XCTAssertEqual(UpdateTestSupport.fingerprint(of: installed), before, "the installed app is byte-identical")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Isla.app"])
        for folder in scratch.folders { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path)) }
        XCTAssertEqual(mountedImages(), [])
    }
}

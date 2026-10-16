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
        downloader.configuration = {
            let configuration = PrivateNetwork.makeConfiguration()
            configuration.protocolClasses = [StubGitHub.self]
            return configuration
        }
        return UpdateInstaller(
            environment: environment, downloader: downloader,
            validator: BundleUpdateValidator(runningVersion: "1.0", runningBuild: "1"),
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

/// Answers the two release URLs from memory with a 200 and the file's length,
/// so the downloader's own delegate runs against a real `URLSession` with
/// nothing leaving the Mac.
final class StubGitHub: URLProtocol {
    nonisolated(unsafe) private static var files: [URL: Data] = [:]
    private static let lock = NSLock()

    static func serve(_ url: URL, _ data: Data) { lock.lock(); files[url] = data; lock.unlock() }
    static func clear() { lock.lock(); files = [:]; lock.unlock() }
    private static func data(for url: URL) -> Data? { lock.lock(); defer { lock.unlock() }; return files[url] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let data = Self.data(for: url) else {
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://invalid")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)", "Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, so progress is reported more than once.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 * 1024, data.count)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

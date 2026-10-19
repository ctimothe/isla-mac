import Foundation
import XCTest
@testable import IslaKit

/// The update rehearsal (`DI_UPDATE_REHEARSAL=<folder>`): Update Now taking its
/// release from a local folder, so an update can be tried on a real Mac before a
/// real release exists. Only the source of the release changes; what these hold is
/// that the source is exactly that folder, that it is off unless asked for, and
/// that it is read once and from one place.
@MainActor
final class UpdateRehearsalTests: XCTestCase {
    private let page = "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1"

    private func release(in folder: URL, dmgURL: String? = nil, sigURL: String? = nil, tag: String = "v0.3.1") -> Data {
        let dmg = dmgURL ?? "file://\(folder.path)/Isla-0.3.1.dmg"
        let sig = sigURL ?? "file://\(folder.path)/Isla-0.3.1.dmg.sig"
        let object: [String: Any] = [
            "tag_name": tag, "html_url": page, "body": "Rehearsal build.", "draft": false, "prerelease": false,
            "assets": [
                ["name": "Isla-0.3.1.dmg", "size": 1234, "browser_download_url": dmg],
                ["name": "Isla-0.3.1.dmg.sig", "size": 88, "browser_download_url": sig],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func rehearsalFolder() throws -> URL {
        try UpdateTestSupport.folder(self).resolvingSymlinksInPath()
    }

    private func available(_ data: Data, rehearsal: URL?) -> UpdateCheck.Release? {
        if case .available(let release) = UpdateCheck.state(forRelease: data, localVersion: "0.3.0", rehearsal: rehearsal) { return release }
        return nil
    }

    // MARK: The hook

    func testTheFolderIsReadFromTheEnvironmentOnlyWhenItNamesAFolder() throws {
        let folder = try rehearsalFolder()
        XCTAssertNil(DebugTrail.rehearsalFolder(from: [:]), "off unless set")
        XCTAssertNil(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": ""]))
        XCTAssertNil(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": "relative/path"]))
        XCTAssertNil(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": folder.appendingPathComponent("missing").path]))
        let file = folder.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertNil(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": file.path]), "a file is not a folder")
        XCTAssertEqual(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": folder.path]), folder)
        XCTAssertNil(DebugTrail.rehearsalFolder(from: ["DI_UPDATE": folder.path, "DI_GEOM": "1"]), "no other variable stands in")
        let link = folder.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(DebugTrail.rehearsalFolder(from: ["DI_UPDATE_REHEARSAL": link.path]), folder, "symlinks resolved")
    }

    /// A normal test run has the hook off, and it is a `static let`: read once.
    func testTheHookIsOffInATestRunAndReadOnce() {
        XCTAssertNil(DebugTrail.updateRehearsal)
        XCTAssertFalse(UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }).isRehearsal)
    }

    /// The variable is named in one source file and read there; every other file
    /// asks `DebugTrail`. (Comments may name it.)
    func testNoSourceButDebugTrailReadsTheVariable() throws {
        let sources = VisualLab.repositoryRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var readers: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//"), code.contains("DI_UPDATE_REHEARSAL") { readers.append(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(Set(readers), ["DebugTrail.swift"])
    }

    // MARK: The release

    func testAReleaseFileInTheFolderIsReadInsteadOfGitHub() async throws {
        let folder = try rehearsalFolder()
        try release(in: folder).write(to: folder.appendingPathComponent("release.json"))
        let asked = Counter()
        let check = UpdateCheck(fetch: { _ in asked.bump(); throw URLError(.notConnectedToInternet) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        XCTAssertTrue(check.isRehearsal)
        check.check()
        for _ in 0..<400 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        guard case .available(let found) = check.state else { return XCTFail("\(check.state)") }
        XCTAssertEqual(found.version, "0.3.1")
        XCTAssertEqual(found.notes, "Rehearsal build.")
        XCTAssertEqual(found.dmg?.url, URL(string: "file://\(folder.path)/Isla-0.3.1.dmg"))
        XCTAssertEqual(found.signature?.url, URL(string: "file://\(folder.path)/Isla-0.3.1.dmg.sig"))
        XCTAssertEqual(found.page, URL(string: page))
        XCTAssertEqual(asked.value, 0, "nothing was requested from anywhere")
    }

    func testAMissingReleaseFileIsAFailedCheckNotACrash() async throws {
        let folder = try rehearsalFolder()
        let check = UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        check.check()
        for _ in 0..<400 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        if case .failed = check.state {} else { XCTFail("\(check.state)") }
    }

    func testRehearsalOffIgnoresTheFolderEntirely() async throws {
        let folder = try rehearsalFolder()
        try release(in: folder, tag: "v9.9.9").write(to: folder.appendingPathComponent("release.json"))
        let asked = Counter()
        let github = Data(#"{"tag_name":"v0.3.0","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v0.3.0"}"#.utf8)
        let check = UpdateCheck(
            fetch: { request in
                asked.bump()
                return (github, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            currentVersion: { "0.3.0" }, rehearsal: nil
        )
        check.check()
        for _ in 0..<400 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(check.state, .upToDate(version: "0.3.0"), "the folder's 9.9.9 was never looked at")
        XCTAssertEqual(asked.value, 1)
    }

    // MARK: The asset rule

    func testTheTwoExactFileURLsAreAccepted() throws {
        let folder = try rehearsalFolder()
        let found = try XCTUnwrap(available(release(in: folder), rehearsal: folder))
        XCTAssertNotNil(found.dmg)
        XCTAssertNotNil(found.signature)
        XCTAssertTrue(found.isInstallable)
    }

    private func refused(_ dmg: String, _ message: String, in folder: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try XCTUnwrap(available(release(in: folder, dmgURL: dmg), rehearsal: folder), message, file: file, line: line)
        XCTAssertNil(found.dmg, message, file: file, line: line)
        XCTAssertNotNil(found.signature, "the other asset is judged on its own: \(message)", file: file, line: line)
    }

    func testAFileOutsideTheFolderIsRefused() throws {
        let folder = try rehearsalFolder()
        let elsewhere = try rehearsalFolder()
        try refused("file://\(elsewhere.path)/Isla-0.3.1.dmg", "a file in another folder", in: folder)
        try refused("file:///private/tmp/Isla-0.3.1.dmg", "a file in /tmp", in: folder)
        try refused("file://\(folder.path)/sub/Isla-0.3.1.dmg", "a file in a subfolder", in: folder)
        try refused("file://\(folder.path)/Isla-0.3.0.dmg", "another file of the folder", in: folder)
        try refused("file://\(folder.path)/release.json", "the release file itself", in: folder)
    }

    func testADotDotPathIsRefusedEvenWhenItLandsInTheFolder() throws {
        let folder = try rehearsalFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try refused("file://\(folder.path)/sub/../Isla-0.3.1.dmg", "a path that goes down and back up", in: folder)
        try refused("file://\(folder.path)/../\(folder.lastPathComponent)/Isla-0.3.1.dmg", "a path that goes out and back in", in: folder)
    }

    func testASymlinkPointingOutIsRefused() throws {
        let folder = try rehearsalFolder()
        let elsewhere = try rehearsalFolder()
        let target = elsewhere.appendingPathComponent("Isla-0.3.1.dmg")
        try Data("not the folder's".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Isla-0.3.1.dmg"), withDestinationURL: target)
        try refused("file://\(folder.path)/Isla-0.3.1.dmg", "a link named like the file that leads out", in: folder)
    }

    func testAnHTTPSURLIsRefusedInARehearsal() throws {
        let folder = try rehearsalFolder()
        try refused("https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg", "GitHub's own URL", in: folder)
        try refused("https://evil.example/Isla-0.3.1.dmg", "any other", in: folder)
        try refused("file://\(folder.path)/Isla-0.3.1.dmg?x=1", "a query", in: folder)
        try refused("file://\(folder.path)/Isla-0.3.1.dmg#x", "a fragment", in: folder)
        try refused("file://evil.example\(folder.path)/Isla-0.3.1.dmg", "a host", in: folder)
    }

    func testAFileURLIsRefusedOutsideARehearsal() throws {
        let folder = try rehearsalFolder()
        let found = try XCTUnwrap(available(release(in: folder), rehearsal: nil))
        XCTAssertNil(found.dmg)
        XCTAssertNil(found.signature)
        XCTAssertFalse(found.isInstallable)
    }

    func testTheReleasePageStillHasToBeGitHubs() throws {
        let folder = try rehearsalFolder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: release(in: folder)) as? [String: Any])
        object["html_url"] = "https://evil.example/ctimothe/isla-mac/releases/tag/v0.3.1"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(UpdateCheck.state(forRelease: data, localVersion: "0.3.0", rehearsal: folder), .failed(.server))
    }

    // MARK: The installer and the downloader

    func testTheInstallerAcceptsRehearsalAssetsOnlyInARehearsal() throws {
        let folder = try rehearsalFolder()
        let found = try XCTUnwrap(available(release(in: folder), rehearsal: folder))
        var environment = UpdateEnvironment.neverInstalls
        environment.installedURL = folder.appendingPathComponent("Apps/Isla.app")
        environment.isWritable = { _ in true }
        environment.canReplace = { _ in true }
        environment.publicKey = UpdateTestSupport.Key().publicBase64
        environment.rehearsal = folder
        XCTAssertNil(UpdateInstaller(environment: environment).manualReason(for: found))
        environment.rehearsal = nil
        XCTAssertEqual(UpdateInstaller(environment: environment).manualReason(for: found), .noImage)
        // And in a rehearsal GitHub's own URLs are not accepted.
        let github = try XCTUnwrap(available(
            release(in: folder, dmgURL: "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"), rehearsal: nil
        ))
        environment.rehearsal = folder
        XCTAssertEqual(UpdateInstaller(environment: environment).manualReason(for: github), .noImage)
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func note(_ v: Int64) { lock.withLock { values.append(v) } }
        var all: [Int64] { lock.withLock { values } }
    }

    func testTheDownloaderCopiesAFileFromTheFolderWithProgress() async throws {
        let folder = try rehearsalFolder()
        let scratch = try rehearsalFolder()
        let data = Data((0..<700_000).map { UInt8($0 % 241) })
        let source = folder.appendingPathComponent("Isla-0.3.1.dmg")
        try data.write(to: source)
        let progress = Progress()
        let copied = try await URLSessionUpdateDownloader(rehearsal: folder).download(
            from: source, into: scratch, as: "Isla.dmg", expectedBytes: Int64(data.count)
        ) { progress.note($0) }
        XCTAssertEqual(try Data(contentsOf: copied), data)
        XCTAssertEqual(copied.deletingLastPathComponent(), scratch)
        XCTAssertGreaterThan(progress.all.count, 1, "reported in pieces")
        XCTAssertEqual(progress.all, progress.all.sorted())
        XCTAssertEqual(progress.all.last, Int64(data.count))
    }

    func testTheDownloaderRefusesFileURLsOutsideARehearsalAndOutsideTheFolder() async throws {
        let folder = try rehearsalFolder()
        let scratch = try rehearsalFolder()
        let outside = try rehearsalFolder().appendingPathComponent("Isla-0.3.1.dmg")
        try Data("x".utf8).write(to: outside)
        let inside = folder.appendingPathComponent("Isla-0.3.1.dmg")
        try Data("x".utf8).write(to: inside)
        for (label, downloader, url) in [
            ("no rehearsal", URLSessionUpdateDownloader(rehearsal: nil), inside),
            ("outside the folder", URLSessionUpdateDownloader(rehearsal: folder), outside),
        ] {
            do {
                _ = try await downloader.download(from: url, into: scratch, as: "Isla.dmg", expectedBytes: 10) { _ in }
                XCTFail("\(label) must be refused")
            } catch {
                XCTAssertEqual(error as? UpdateDownloadError, .badResponse, label)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testTheCopyHoldsTheSizeCapAndLeavesNothingBehind() async throws {
        let folder = try rehearsalFolder()
        let scratch = try rehearsalFolder()
        let source = folder.appendingPathComponent("Isla-0.3.1.dmg")
        try Data(repeating: 1, count: 100_000).write(to: source)
        do {
            _ = try await URLSessionUpdateDownloader(rehearsal: folder).download(from: source, into: scratch, as: "Isla.dmg", expectedBytes: 50_000) { _ in }
            XCTFail("over the advertised size")
        } catch {
            XCTAssertEqual(error as? UpdateDownloadError, .tooLarge)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        let missing = folder.appendingPathComponent("Isla-0.3.2.dmg")
        do {
            _ = try await URLSessionUpdateDownloader(rehearsal: folder).download(from: missing, into: scratch, as: "Isla.dmg", expectedBytes: 50_000) { _ in }
            XCTFail("a missing file")
        } catch {
            XCTAssertEqual(error as? UpdateDownloadError, .badResponse)
        }
    }

    func testCancellingTheCopyStopsItAndDeletesThePartialFile() async throws {
        let folder = try rehearsalFolder()
        let scratch = try rehearsalFolder()
        let source = folder.appendingPathComponent("Isla-0.3.1.dmg")
        try Data(repeating: 1, count: 20_000_000).write(to: source)
        let task = Task {
            try await URLSessionUpdateDownloader(rehearsal: folder).download(
                from: source, into: scratch, as: "Isla.dmg", expectedBytes: 20_000_000
            ) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    // MARK: Files that are not files

    /// Waits for a task that must finish quickly, and says so if it does not.
    private func finishes<T: Sendable>(_ seconds: TimeInterval = 3, _ body: @escaping @Sendable () async -> T) async -> T? {
        let box = ResultBox<T>()
        let task = Task { box.set(await body()) }
        for _ in 0..<Int(seconds * 200) where box.value == nil { try? await Task.sleep(for: .milliseconds(5)) }
        if box.value == nil { task.cancel() }
        return box.value
    }

    private func fifo(at url: URL) throws {
        XCTAssertEqual(mkfifo(url.path, 0o600), 0, "mkfifo")
    }

    func testAFIFOAtTheAssetPathFailsQuicklyInsteadOfHangingTheCopy() async throws {
        let folder = try rehearsalFolder()
        let scratch = try rehearsalFolder()
        let path = folder.appendingPathComponent("Isla-0.3.1.dmg")
        try fifo(at: path)
        let outcome = await finishes { () -> String in
            do {
                _ = try await URLSessionUpdateDownloader(rehearsal: folder).download(from: path, into: scratch, as: "Isla.dmg", expectedBytes: 1000) { _ in }
                return "downloaded"
            } catch { return "\(error)" }
        }
        XCTAssertEqual(outcome, "\(UpdateDownloadError.badResponse)", "refused, and quickly")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testOnlyARegularFileIsOpened() throws {
        let folder = try rehearsalFolder()
        let regular = folder.appendingPathComponent("regular")
        try Data("abc".utf8).write(to: regular)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let pipe = folder.appendingPathComponent("pipe")
        try fifo(at: pipe)
        XCTAssertEqual(SafeFile.openRegular(regular)?.size, 3)
        XCTAssertNil(SafeFile.openRegular(link), "never through a link")
        XCTAssertNil(SafeFile.openRegular(pipe))
        XCTAssertNil(SafeFile.openRegular(folder), "a folder is not a file")
        XCTAssertNil(SafeFile.openRegular(URL(fileURLWithPath: "/dev/null")), "nor a device")
        XCTAssertNil(SafeFile.openRegular(folder.appendingPathComponent("missing")))
        XCTAssertEqual(SafeFile.readRegular(regular, limit: 3), Data("abc".utf8))
        XCTAssertNil(SafeFile.readRegular(regular, limit: 2), "over the limit")
    }

    func testAFIFOForReleaseJSONFailsTheCheckQuickly() async throws {
        let folder = try rehearsalFolder()
        try fifo(at: folder.appendingPathComponent("release.json"))
        let check = UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        check.check()
        let ended = await finishes { await MainActor.run { check.state != .checking } ? true : await Self.settle(check) }
        XCTAssertEqual(ended, true)
        if case .failed = check.state {} else { XCTFail("\(check.state)") }
    }

    private static func settle(_ check: UpdateCheck) async -> Bool {
        for _ in 0..<600 {
            if await MainActor.run(body: { check.state != .checking }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testAnOversizedReleaseJSONIsRefused() async throws {
        let folder = try rehearsalFolder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: release(in: folder)) as? [String: Any])
        object["body"] = String(repeating: "x", count: UpdateCheck.rehearsalReleaseLimit + 10)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("release.json"))
        let check = UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        check.check()
        _ = await Self.settle(check)
        if case .failed = check.state {} else { XCTFail("\(check.state)") }
    }

    func testASymlinkedReleaseJSONIsRefused() async throws {
        let folder = try rehearsalFolder()
        let elsewhere = try rehearsalFolder()
        try release(in: folder).write(to: elsewhere.appendingPathComponent("release.json"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("release.json"), withDestinationURL: elsewhere.appendingPathComponent("release.json")
        )
        let check = UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        check.check()
        _ = await Self.settle(check)
        if case .failed = check.state {} else { XCTFail("\(check.state)") }
    }

    // MARK: What the person sees

    func testTheCardSaysItIsARehearsal() {
        let release = UpdateCheck.Release(version: "0.3.1", page: URL(string: page)!)
        let on = UpdatePresentation.make(
            check: .available(release), known: release, phase: .idle, installerRelease: nil, manualReason: nil,
            runningVersion: "0.3.0", rehearsal: true
        )
        XCTAssertEqual(on.sourceNote, "Rehearsal: update from a local folder")
        let off = UpdatePresentation.make(
            check: .available(release), known: release, phase: .idle, installerRelease: nil, manualReason: nil, runningVersion: "0.3.0"
        )
        XCTAssertNil(off.sourceNote)
    }

    func testThePaneShowsTheRehearsalLineOnlyDuringARehearsal() async throws {
        let folder = try rehearsalFolder()
        try release(in: folder).write(to: folder.appendingPathComponent("release.json"))
        let rehearsing = UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, rehearsal: folder)
        rehearsing.check()
        for _ in 0..<400 where rehearsing.lastAvailable == nil { try await Task.sleep(for: .milliseconds(5)) }
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let on = await SettingsFixture.tree(isolated, section: .about, updates: rehearsing)
        XCTAssertTrue(on.dump.contains("Rehearsal: update from a local folder"), on.dump)
        let normal = await SettingsFixture.tree(isolated, section: .about)
        XCTAssertFalse(normal.dump.contains("Rehearsal"), normal.dump)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.withLock { stored = value } }
    var value: T? { lock.withLock { stored } }
}

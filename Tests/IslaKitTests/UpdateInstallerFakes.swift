import Combine
import Foundation
import XCTest
@testable import IslaKit

// The fakes the installer tests run on. Each one keeps what it was asked, in
// order, so a test says "the image was never attached" or "detach came last"
// by looking at a list. They are called from the installer's own task and from
// nonisolated async functions, so each guards its state with a lock.

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func note(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func count(_ entry: String) -> Int { all.filter { $0 == entry }.count }
}

final class FakeDownloader: UpdateDownloading, @unchecked Sendable {
    let log: Recorder
    var imageData = Data("the image".utf8)
    var signatureData = Data("the signature".utf8)
    var failure: Error?
    var failImageOnly = false
    /// Writes a partial image, then waits until the task is cancelled.
    var holdImage = false
    /// What the progress callback is told, in order, for the image.
    var progress: [Int64] = []
    private(set) var folders: [URL] = []

    init(log: Recorder) { self.log = log }

    func download(
        from url: URL, into folder: URL, as fileName: String, expectedBytes: Int64,
        progress report: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        log.note("download \(fileName)")
        let isImage = fileName == UpdateInstaller.imageFileName
        folders.append(folder)
        if let failure, !failImageOnly || isImage { throw failure }
        let destination = folder.appendingPathComponent(fileName)
        if isImage, holdImage {
            try imageData.prefix(3).write(to: destination)
            report(3)
            while true {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: destination)
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try (isImage ? imageData : signatureData).write(to: destination)
        if isImage { for step in progress { report(step) } }
        return destination
    }
}

final class FakeVerifier: UpdateVerifying, @unchecked Sendable {
    let log: Recorder
    var valid = true
    private(set) var seenSignature: String?
    private(set) var imageExisted = false

    init(log: Recorder) { self.log = log }

    func isValid(signatureBase64: String, fileURL: URL) async -> Bool {
        log.note("verify")
        seenSignature = signatureBase64
        imageExisted = FileManager.default.fileExists(atPath: fileURL.path)
        return valid
    }
}

final class FakeDiskImage: UpdateDiskImaging, @unchecked Sendable {
    let log: Recorder
    var attachError: Error?
    /// What `detach` answers: false is a volume that will not let go.
    var detaches = true
    private(set) var mounts: [UpdateMount] = []
    private(set) var detached: [UpdateMount] = []

    init(log: Recorder) { self.log = log }

    func attach(_ image: URL, scratch: URL) async throws -> UpdateMount {
        log.note("attach")
        if let attachError { throw attachError }
        let folder = scratch.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mount = UpdateMount(mountPoint: folder, devices: ["/dev/disk99"])
        mounts.append(mount)
        return mount
    }

    func detach(_ mount: UpdateMount) async -> Bool {
        log.note("detach")
        detached.append(mount)
        return detaches
    }
}

final class FakeStager: UpdateStaging, @unchecked Sendable {
    let log: Recorder
    var error: Error?
    /// Waits, politely, until the task is cancelled: a tool that hung.
    var hangs = false
    var marker = "new"
    private(set) var stagedApps: [URL] = []

    init(log: Recorder) { self.log = log }

    func stage(volume: URL, into stagingFolder: URL) async throws -> URL {
        log.note("stage")
        if hangs { while true { try await Task.sleep(for: .milliseconds(5)) } }
        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        let app = stagingFolder.appendingPathComponent("Isla.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker.txt"))
        // A failure after the copy began: the folder exists and has contents.
        if let error { throw error }
        stagedApps.append(app)
        return app
    }
}

final class FakeValidator: UpdateValidating, @unchecked Sendable {
    let log: Recorder
    var error: Error?
    private(set) var validated: [URL] = []

    init(log: Recorder) { self.log = log }

    func validate(_ app: URL, release: UpdateCheck.Release) async throws {
        log.note("validate")
        validated.append(app)
        if let error { throw error }
    }
}

/// The real swapper over the test's own real folders, noted in the log. What
/// forces a failure is the real swapper's own seams (`swapper.swap`, `.replace`,
/// `.move`), so a failure happens to real directories and the state it leaves is
/// the state a person would be left in.
final class RecordingSwapper: UpdateSwapping {
    let log: Recorder
    var swapper = FileManagerSwapper()

    init(log: Recorder) { self.log = log }

    func replace(installed: URL, with staged: URL) throws {
        log.note("swap")
        try swapper.replace(installed: installed, with: staged)
    }
}

@MainActor
final class FakeRelauncher: UpdateRelaunching {
    let log: Recorder
    private(set) var calls: [(installed: URL, processID: Int32)] = []
    /// What the test wants looked at while the relaunch is happening: the
    /// process ends there, so this is the last chance anything has to be gone.
    var onRelaunch: () -> Void = {}
    /// False is a shell that could not be started: nothing is relaunched and
    /// the process is not ended.
    var succeeds = true

    init(log: Recorder) { self.log = log }

    func relaunch(installed: URL, processID: Int32) -> Bool {
        log.note("relaunch")
        calls.append((installed, processID))
        onRelaunch()
        return succeeds
    }
}

/// An installer over fakes, in a folder of its own: an installed fake app in
/// `Apps/`, a scratch area, a release whose assets pass the trust rules and
/// whose sizes match what the fake downloader writes.
@MainActor
final class InstallerRig {
    let root: URL
    let apps: URL
    let installed: URL
    let scratchRoot: URL
    let log = Recorder()
    let key = UpdateTestSupport.Key()
    let downloader: FakeDownloader
    let verifier: FakeVerifier
    let diskImage: FakeDiskImage
    let stager: FakeStager
    let validator: FakeValidator
    let swapper: RecordingSwapper
    let relauncher: FakeRelauncher
    private(set) var scratchFolders: [URL] = []
    var freeBytes: Int64? = 10_000_000_000
    /// Free space on the volume the download and the mount live on.
    var scratchFreeBytes: Int64? = 10_000_000_000
    var publicKey: String?
    var installedPath: URL
    var writable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    var canReplace: (URL) -> Bool = { UpdateInstaller.currentUserCanReplace($0) }
    /// Answers "is a volume still mounted under this folder"; the real check by
    /// default, which is no for any folder a fake made.
    var containsMount: (URL) -> Bool = { UpdateInstaller.directoryContainsMount($0) }
    var installTimeout: TimeInterval = 30
    private(set) var installer: UpdateInstaller!
    private(set) var phases: [UpdateInstaller.Phase] = []
    private var subscription: AnyCancellable?

    init(_ test: XCTestCase) throws {
        root = try UpdateTestSupport.folder(test)
        apps = root.appendingPathComponent("Apps", isDirectory: true)
        scratchRoot = root.appendingPathComponent("Scratch", isDirectory: true)
        installed = apps.appendingPathComponent("Isla.app", isDirectory: true)
        installedPath = installed
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker.txt"))
        downloader = FakeDownloader(log: log)
        verifier = FakeVerifier(log: log)
        diskImage = FakeDiskImage(log: log)
        stager = FakeStager(log: log)
        validator = FakeValidator(log: log)
        swapper = RecordingSwapper(log: log)
        relauncher = FakeRelauncher(log: log)
        publicKey = key.publicBase64
    }

    /// Builds the installer, after the test has said how the Mac looks.
    func build() {
        let installedURL = installedPath
        let scratchRoot = scratchRoot
        let capacity = freeBytes
        let scratchCapacity = scratchFreeBytes
        let writable = writable
        let canReplace = canReplace
        let containsMount = containsMount
        let timeout = installTimeout
        let key = publicKey
        let environment = UpdateEnvironment(
            installedURL: installedURL, publicKey: key, processID: 4242,
            availableCapacity: { url in url.path == scratchRoot.path ? scratchCapacity : capacity },
            isWritable: writable,
            canReplace: canReplace,
            containsMount: containsMount,
            scratchRoot: scratchRoot,
            makeScratchFolder: { [weak self] in
                let folder = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                MainActor.assumeIsolated { self?.scratchFolders.append(folder) }
                return folder
            }
        )
        installer = UpdateInstaller(
            environment: environment, downloader: downloader, verifier: verifier, diskImage: diskImage,
            stager: stager, validator: validator, swapper: swapper, relauncher: relauncher,
            installTimeout: timeout
        )
        subscription = installer.$phase.sink { [weak self] phase in self?.phases.append(phase) }
    }

    func release(image: Bool = true, signature: Bool = true, version: String = "0.3.1") -> UpdateCheck.Release {
        let base = "https://github.com/ctimothe/isla-mac/releases/download/v\(version)/"
        return UpdateCheck.Release(
            version: version,
            page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v\(version)")!,
            notes: "notes",
            dmg: image ? .init(name: "Isla-\(version).dmg", url: URL(string: base + "Isla-\(version).dmg")!,
                               size: Int64(downloader.imageData.count)) : nil,
            signature: signature ? .init(name: "Isla-\(version).dmg.sig", url: URL(string: base + "Isla-\(version).dmg.sig")!,
                                        size: Int64(downloader.signatureData.count)) : nil
        )
    }

    /// Polls until `condition` holds or five seconds pass.
    func until(_ message: String = "", _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out: \(message)", file: file, line: line)
    }

    /// Until the installer is no longer working: it failed, was cancelled, or
    /// reached the relaunch.
    func finish() async {
        await until("the install to end") {
            switch installer.phase {
            case .failed, .manualOnly: return true
            case .idle: return phases.contains { if case .downloading = $0 { return true } else { return false } }
            case .relaunching: return !relauncher.calls.isEmpty
            default: return false
            }
        }
        // Let the task's cleanup finish.
        try? await Task.sleep(for: .milliseconds(30))
    }

    var installedFingerprint: String { UpdateTestSupport.fingerprint(of: installed) }

    func leftovers() -> [String] {
        var found: [String] = []
        for folder in scratchFolders where FileManager.default.fileExists(atPath: folder.path) { found.append(folder.lastPathComponent) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
        found += names.filter { $0.hasPrefix(UpdateInstaller.stagingPrefix) }
        return found
    }
}

import AppKit
import Darwin
import Foundation
import Security

// The production side of `UpdateInstaller`'s seams. Each is small and does one
// thing; the order of them, and what happens when one fails, is the installer's.

// MARK: - Download

enum UpdateDownloadError: Error, Equatable {
    /// An answer that is not HTTP 200 once redirects are followed.
    case badStatus(Int)
    /// More bytes than the release advertised.
    case tooLarge
    /// No answer to speak of: not HTTP at all, or no file.
    case badResponse
}

/// A `URLSession` download task with byte progress and cancel, over the same
/// configuration as every other request Isla makes (`PrivateNetwork`: no cache,
/// no cookies, no credential store).
///
/// Redirects are followed, because GitHub serves a release asset from its own
/// asset network and not from the URL the release names — but only to https. The
/// signature, not the host, is what protects the content; the redirect rule is
/// the one thing the transport can add, and it costs nothing.
///
/// The transfer is stopped the moment it passes the advertised size, so a server
/// cannot fill the disk with a download that was said to be ten megabytes, and a
/// partial file is deleted whenever the transfer does not finish.
struct URLSessionUpdateDownloader: UpdateDownloading {
    /// Makes the session for one transfer, given its delegate. Only
    /// `PrivateNetwork` may build one; a test replaces this to answer the wire.
    var makeSession: @Sendable (URLSessionDelegate) -> URLSession = {
        PrivateNetwork.makeSession(delegate: $0, requestTimeout: 30, resourceTimeout: 15 * 60)
    }
    /// The folder releases are read from — a rehearsal's or the local feed's
    /// (`UpdateSource`) — the only place a file URL is accepted from; nil, which
    /// is GitHub, accepts none.
    var rehearsal: URL?
    /// Whether the folder may still be read (`UpdateSource.stillHolds`), asked
    /// before every copy out of it.
    var folderStillHolds: @Sendable () -> Bool = { true }

    init(rehearsal: URL?) { self.rehearsal = rehearsal }

    init(source: UpdateSource = .current) {
        self.rehearsal = source.folder
        self.folderStillHolds = { source.stillHolds() }
    }

    func download(
        from url: URL, into folder: URL, as fileName: String, expectedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let destination = folder.appendingPathComponent(fileName)
        if url.isFileURL {
            // A file URL is a rehearsal's, and only inside the rehearsal folder.
            guard let rehearsal, folderStillHolds(),
                  UpdateCheck.isRehearsalFile(url, named: url.lastPathComponent, in: rehearsal) else {
                throw UpdateDownloadError.badResponse
            }
            return try await copy(url, to: destination, expectedBytes: expectedBytes, progress: progress)
        }
        let transfer = Transfer(destination: destination, expectedBytes: expectedBytes, progress: progress)
        let session = makeSession(transfer)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Isla/\(ProductIdentity.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.begin(session.downloadTask(with: request), continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    /// The copy that stands in for a download of a local file: URLSession answers
    /// a file URL with no HTTP status to check, so the file is copied here, in
    /// pieces, through the same rules — over the advertised size is `tooLarge`,
    /// progress is the bytes copied so far, cancelling stops it, and a partial
    /// file is deleted on every failure.
    private func copy(
        _ source: URL, to destination: URL, expectedBytes: Int64, progress: @Sendable (Int64) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        // A regular file, opened without following a link and without blocking:
        // a FIFO or a device at that path would otherwise hang the copy, and
        // Cancel cannot stop a read that is waiting for a writer.
        guard let opened = SafeFile.openRegular(source) else { throw UpdateDownloadError.badResponse }
        let size = opened.size
        guard size <= expectedBytes else { try? opened.handle.close(); throw UpdateDownloadError.tooLarge }
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            try? opened.handle.close()
            throw UpdateDownloadError.badResponse
        }
        do {
            let input = opened.handle
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                copied += Int64(chunk.count)
                if copied > expectedBytes { throw UpdateDownloadError.tooLarge }
                try output.write(contentsOf: chunk)
                progress(copied)
                await Task.yield()
            }
            return destination
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Whether a redirect may be followed.
    static func allowsRedirect(to url: URL?) -> Bool { url?.scheme == "https" }

    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let expectedBytes: Int64
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        private var overran = false
        private var status: Int?
        private var moved = false
        private var moveError: Error?

        init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        func begin(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
            lock.lock()
            self.continuation = continuation
            self.task = task
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled { task.cancel() }
            task.resume()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesWritten > expectedBytes {
                lock.lock(); overran = true; lock.unlock()
                downloadTask.cancel()
                return
            }
            progress(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(URLSessionUpdateDownloader.allowsRedirect(to: request.url) ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode
            lock.lock(); status = code; lock.unlock()
            guard code == 200 else { return }
            // A body longer than advertised can arrive in one piece, with no
            // `didWriteData` in between to stop it.
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int64 ?? 0
            if size > expectedBytes {
                lock.lock(); overran = true; lock.unlock()
                return
            }
            // The temporary file is deleted when this returns, so the move is
            // here and nowhere later.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                lock.lock(); moved = true; lock.unlock()
            } catch {
                lock.lock(); moveError = error; lock.unlock()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let result: Result<URL, Error>
            if overran {
                result = .failure(UpdateDownloadError.tooLarge)
            } else if cancelled {
                result = .failure(CancellationError())
            } else if let error {
                result = .failure(error)
            } else if let moveError {
                result = .failure(moveError)
            } else if let status, status != 200 {
                result = .failure(UpdateDownloadError.badStatus(status))
            } else if status == nil {
                result = .failure(UpdateDownloadError.badResponse)
            } else if moved {
                result = .success(destination)
            } else {
                result = .failure(UpdateDownloadError.badResponse)
            }
            lock.unlock()
            if case .failure = result { try? FileManager.default.removeItem(at: destination) }
            continuation?.resume(with: result)
        }
    }
}

// MARK: - Local files

/// Reading a local file that came out of a JSON file or a folder somebody else
/// can write to: a regular file only, never a link, a FIFO or a device.
enum SafeFile {
    struct Opened {
        let handle: FileHandle
        let size: Int64
    }

    /// The file opened for reading, or nil unless it is a regular file. `lstat`
    /// says so, the open does not follow a link (`O_NOFOLLOW`) and does not
    /// wait for a writer (`O_NONBLOCK`), `fstat` says so again on the descriptor
    /// that was actually opened, and only then is blocking restored, which a
    /// regular file never does.
    static func openRegular(_ url: URL) -> Opened? {
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var after = stat()
        guard fstat(descriptor, &after) == 0, (after.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        return Opened(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), size: Int64(after.st_size))
    }

    /// A small regular file's bytes, or nil if it is not one or is over `limit`.
    static func readRegular(_ url: URL, limit: Int) -> Data? {
        guard let opened = openRegular(url), opened.size <= Int64(limit) else { return nil }
        defer { try? opened.handle.close() }
        return try? opened.handle.read(upToCount: limit + 1).flatMap { $0.count <= limit ? $0 : nil }
    }
}

// MARK: - Verify

struct Ed25519UpdateVerifier: UpdateVerifying {
    var publicKey: String

    func isValid(signatureBase64: String, fileURL: URL) async -> Bool {
        UpdateSignature.isValid(signatureBase64: signatureBase64, publicKeyBase64: publicKey, fileURL: fileURL)
    }
}

// MARK: - Processes

/// Runs a system tool the way the installer needs it: an argument array and
/// never a shell string, nothing on its stdin, its output collected, and a
/// deadline after which it is ended — SIGTERM, then SIGKILL after `killGrace`.
///
/// The output is read as it arrives, through the pipe's readability handler, and
/// the run ends when the *process* does, with a short grace for the rest of the
/// output. A blocking `readDataToEndOfFile` waits for every holder of the pipe's
/// write end, and a tool that has started a child (or hung) holds it for as long
/// as it likes. Cancelling the task ends the process the same way, which is what
/// lets a ceiling on the installing phase actually stop a hung `hdiutil`.
enum UpdateTool {
    struct Result: Equatable {
        let status: Int32
        let output: Data
        let timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// How a process is told to stop. Properties so a test can stand in a
    /// process that ignores both: `terminate` is SIGTERM, `kill` SIGKILL.
    struct Signals: Sendable {
        var terminate: @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGTERM) }
        var kill: @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGKILL) }
    }

    /// A tool that has still not gone this long after SIGKILL is given up on:
    /// the run returns anyway, `timedOut`, so nothing that awaits it waits
    /// forever on a process in a state no signal reaches.
    static func run(
        _ executable: String, _ arguments: [String],
        timeout: TimeInterval = 120, killGrace: TimeInterval = 3, drainGrace: TimeInterval = 1,
        signals: Signals = Signals(), afterLaunch: (@Sendable () -> Void)? = nil
    ) async -> Result? {
        let job = Job(
            executable: executable, arguments: arguments, timeout: timeout, killGrace: killGrace,
            drainGrace: drainGrace, signals: signals, afterLaunch: afterLaunch
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in job.start(continuation) }
        } onCancel: {
            job.cancel()
        }
    }

    /// Runs `body` in a task of its own, which a cancelled caller cannot end:
    /// the cleanup after a cancelled or timed-out step (detaching an image) must
    /// run to the end, and a cancelled task would end its first tool at once.
    static func uncancellable<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(operation: body).value
    }

    private final class Job: @unchecked Sendable {
        private let executable: String
        private let arguments: [String]
        private let timeout: TimeInterval
        private let killGrace: TimeInterval
        private let drainGrace: TimeInterval
        private let signals: Signals
        private let afterLaunch: (@Sendable () -> Void)?
        private let lock = NSLock()
        private let process = Process()
        private let pipe = Pipe()
        private var continuation: CheckedContinuation<Result?, Never>?
        private var buffer = Data()
        private var started = false
        private var ended = false
        private var status: Int32 = 0
        private var timedOut = false
        private var cancelledEarly = false
        private var finished = false
        private var eof = false

        init(
            executable: String, arguments: [String], timeout: TimeInterval, killGrace: TimeInterval,
            drainGrace: TimeInterval, signals: Signals, afterLaunch: (@Sendable () -> Void)?
        ) {
            self.signals = signals
            self.afterLaunch = afterLaunch
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
            self.killGrace = killGrace
            self.drainGrace = drainGrace
        }

        func start(_ continuation: CheckedContinuation<Result?, Never>) {
            lock.lock()
            self.continuation = continuation
            let early = cancelledEarly
            lock.unlock()
            if early { finish(result: nil); return }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                // Empty is the end of the stream. A handler left in place is
                // called again at once, forever, until the process ends.
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.received(data)
            }
            process.terminationHandler = { [weak self] process in
                self?.processEnded(status: process.terminationStatus)
            }
            do { try process.run() } catch {
                finish(result: nil)
                return
            }
            afterLaunch?()
            lock.lock()
            started = true
            // A cancel that arrived while the process was starting found
            // nothing to stop and left a note; it is read here, under the same
            // lock that says the process is running, so it cannot be lost.
            let cancelled = cancelledEarly && !ended
            lock.unlock()
            if cancelled { endProcess() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire() }
        }

        func cancel() {
            lock.lock()
            let running = started && !ended
            if !started { cancelledEarly = true }
            lock.unlock()
            if running { endProcess() }
        }

        private func expire() {
            lock.lock()
            let running = started && !ended && !finished
            if running { timedOut = true }
            lock.unlock()
            if running { endProcess() }
        }

        /// SIGTERM now, SIGKILL if it is still there after the grace, and if it
        /// is *still* there after another, the run is finished without it.
        private func endProcess() {
            let pid = process.processIdentifier
            // A process that is already gone has a pid the system may have
            // given to something else; nothing is signalled then.
            lock.lock(); let alive = !ended; lock.unlock()
            guard alive else { return }
            signals.terminate(pid)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let alive = !self.ended; self.lock.unlock()
                guard alive else { return }
                self.signals.kill(pid)
                DispatchQueue.global().asyncAfter(deadline: .now() + self.killGrace) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let result = Result(status: -1, output: self.buffer, timedOut: true)
                    self.lock.unlock()
                    self.finish(result: result)
                }
            }
        }

        private func received(_ data: Data) {
            lock.lock()
            if data.isEmpty { eof = true } else { buffer.append(data) }
            let done = eof && ended
            lock.unlock()
            if done { finishWithOutput() }
        }

        private func processEnded(status: Int32) {
            lock.lock()
            ended = true
            self.status = status
            let done = eof
            lock.unlock()
            if done { finishWithOutput(); return }
            // A grandchild may still hold the pipe: the process is over, and
            // the rest of its output is not worth waiting for.
            DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) { [weak self] in self?.finishWithOutput() }
        }

        private func finishWithOutput() {
            lock.lock()
            let result = Result(status: status, output: buffer, timedOut: timedOut)
            lock.unlock()
            finish(result: result)
        }

        private func finish(result: Result?) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            continuation?.resume(returning: result)
        }
    }
}

// MARK: - Disk image

enum UpdateImageError: Error, Equatable {
    case attachFailed
    case noMountPoint
    case oneVolumeExpected
    case noApp
    case stageFailed
    /// An image that was attached and could not be detached, after every try.
    /// Its mount point is still a volume: nothing may be deleted under it.
    case stillAttached
}

/// What an attach left: the volume's mount point and the device it is on, which
/// is what `detach` names — a mount point can be a path an attacker made to look
/// like another, and a device cannot.
struct UpdateMount: Equatable, Sendable {
    var mountPoint: URL
    var devices: [String]
}

/// `hdiutil attach` read-only, not browsable, not opened in the Finder, with the
/// image's own checksum pass skipped (the signature already covers every byte)
/// and the mount point chosen by hdiutil under the run's own scratch folder.
///
/// Whatever happens, an image that was attached is detached, by device: after
/// an attach that exited 0 with no mount point, after one that timed out having
/// mounted (found again by its image path in `hdiutil info`), and after the
/// staging that followed. Detaching is tried three times with `-force`, and
/// `false` means the volume is still there.
struct HdiutilDiskImage: UpdateDiskImaging {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> UpdateTool.Result?

    static let hdiutil = "/usr/bin/hdiutil"
    static let detachAttempts = 3
    /// What one cleanup call may take, `hdiutil info` or one detach try. Short
    /// on purpose: cleanup runs after a failure, often after the installing
    /// ceiling has already ended the install, and must not outlast it by minutes.
    static let cleanupTimeout: TimeInterval = 10

    var run: Runner = { await UpdateTool.run($0, $1, timeout: $2, killGrace: 3) }
    var retryDelay: TimeInterval = 0.5

    static func attachArguments(image: URL, scratch: URL) -> [String] {
        ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountrandom", scratch.path, "-plist", image.path]
    }

    func attach(_ image: URL, scratch: URL) async throws -> UpdateMount {
        let result = await run(Self.hdiutil, Self.attachArguments(image: image, scratch: scratch), 60)
        if let result, result.succeeded {
            let mounts = Self.mountPoints(in: result.output)
            var devices = Self.devices(in: result.output)
            if mounts.count == 1, let mount = mounts.first { return UpdateMount(mountPoint: mount, devices: devices) }
            // Exit 0 but not the one volume that was expected: whatever it
            // attached is detached before this gives up.
            if devices.isEmpty { devices = await attachedDevices(for: image) }
            guard await detach(devices: devices) else { throw UpdateImageError.stillAttached }
            throw mounts.isEmpty ? UpdateImageError.noMountPoint : UpdateImageError.oneVolumeExpected
        }
        // Failed or timed out: it may have attached before it died, and there is
        // no plist to say so, so ask for the image by its path.
        let devices = await attachedDevices(for: image)
        if !devices.isEmpty, !(await detach(devices: devices)) { throw UpdateImageError.stillAttached }
        throw UpdateImageError.attachFailed
    }

    func detach(_ mount: UpdateMount) async -> Bool {
        await detach(devices: mount.devices.isEmpty ? [mount.mountPoint.path] : mount.devices)
    }

    func cleanUp(image: URL) async -> Bool {
        let devices = await attachedDevices(for: image)
        return devices.isEmpty ? true : await detach(devices: devices)
    }

    private func detach(devices: [String]) async -> Bool {
        let run = run, retryDelay = retryDelay
        // In a task of its own: this runs after a cancelled or timed-out step,
        // and a cancelled task would end its first tool at once.
        return await UpdateTool.uncancellable {
            var allGone = true
            for device in devices {
                var gone = false
                for attempt in 1...Self.detachAttempts {
                    if let result = await run(Self.hdiutil, ["detach", "-force", device], Self.cleanupTimeout), result.succeeded {
                        gone = true
                        break
                    }
                    if attempt < Self.detachAttempts { try? await Task.sleep(for: .seconds(retryDelay)) }
                }
                if !gone { Log.updates.error("update: a disk image would not detach") }
                allGone = allGone && gone
            }
            return allGone
        }
    }

    /// The devices `hdiutil info` lists for this image file.
    private func attachedDevices(for image: URL) async -> [String] {
        let run = run
        return await UpdateTool.uncancellable {
            guard let info = await run(Self.hdiutil, ["info", "-plist"], Self.cleanupTimeout), info.succeeded else { return [] }
            return Self.devices(inInfo: info.output, imagePath: image.resolvingSymlinksInPath().path)
        }
    }

    /// The mount points in `hdiutil attach -plist` output: every entry of
    /// `system-entities` that has one.
    static func mountPoints(in plist: Data) -> [URL] {
        entities(in: plist).compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    /// The whole-disk devices of the entries (`/dev/disk4`, not `/dev/disk4s1`),
    /// which is what detaches the image and everything on it; the partition
    /// entries if there is no whole-disk one.
    static func devices(in plist: Data) -> [String] {
        wholeDisks(entities(in: plist))
    }

    /// The devices of the images in `hdiutil info -plist` whose file is `imagePath`.
    static func devices(inInfo plist: Data, imagePath: String) -> [String] {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let root = object as? [String: Any], let images = root["images"] as? [[String: Any]]
        else { return [] }
        var found: [String] = []
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == imagePath,
                  let entities = image["system-entities"] as? [[String: Any]]
            else { continue }
            found += wholeDisks(entities)
        }
        return found
    }

    private static func entities(in plist: Data) -> [[String: Any]] {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let root = object as? [String: Any], let entities = root["system-entities"] as? [[String: Any]]
        else { return [] }
        return entities
    }

    private static func wholeDisks(_ entities: [[String: Any]]) -> [String] {
        let all = entities.compactMap { $0["dev-entry"] as? String }
        let whole = all.filter { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil }
        return whole.isEmpty ? all : whole
    }
}

// MARK: - Stage

/// Finds the one `Isla.app` at the root of the volume — a real folder, never a
/// symlink, which could point anywhere — and copies it with `ditto` into the
/// staging folder, which is beside the installed app so the swap is a rename.
struct DittoUpdateStager: UpdateStaging {
    static let appName = "Isla.app"

    func stage(volume: URL, into stagingFolder: URL) async throws -> URL {
        let source = try Self.findApp(in: volume)
        try FileManager.default.createDirectory(
            at: stagingFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let destination = stagingFolder.appendingPathComponent(Self.appName, isDirectory: true)
        guard let result = await UpdateTool.run("/usr/bin/ditto", [source.path, destination.path], timeout: 90),
              result.succeeded
        else { throw UpdateImageError.stageFailed }
        return destination
    }

    /// Exactly one entry named `Isla.app` (any case), exactly that spelling, a
    /// directory and not a link.
    static func findApp(in volume: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: []
        )
        let matches = entries.filter { $0.lastPathComponent.lowercased() == appName.lowercased() }
        guard matches.count == 1, let app = matches.first, app.lastPathComponent == appName else { throw UpdateImageError.noApp }
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw UpdateImageError.noApp }
        return app
    }
}

// MARK: - Validate

enum UpdateValidationError: Error, Equatable {
    case unreadable
    case wrongIdentifier
    case wrongVersion
    case notNewer
    case buildNotNewer
    case signatureInvalid
    /// A valid signature by a different identity than the running app's own,
    /// which would cost Isla its Accessibility and keychain access.
    case identityChanged
}

/// Judges the staged copy, and only the staged copy: whatever the image said,
/// this is what would be run.
///
/// It is Isla (`com.ctimothe.isla`), it is the version the release advertised,
/// that version is newer than the running one and its build number is greater,
/// and its code signature is intact — every file, every architecture, nested
/// code included.
///
/// **Identity.** Isla's Accessibility grant and keychain access belong to its
/// signing identity, so what the update must be signed by depends on what is
/// running. A running app with a real signing identity (a certificate) is
/// replaced only by a copy that satisfies the running app's own *designated
/// requirement*; one that does not is `identityChanged`, and the installer
/// offers the download page instead, because a silent identity change would
/// quietly drop the permissions. A running **ad-hoc** app has no identity to
/// keep — its designated requirement is just the hash of one build, which no
/// update can share — so it accepts any valid signature, and the Ed25519
/// signature over the image, verified before the image was mounted, is the gate.
struct BundleUpdateValidator: UpdateValidating {
    var runningVersion: String
    var runningBuild: String
    var codeIsIntact: @Sendable (URL) -> Bool = { BundleUpdateValidator.codeSignatureIsIntact($0) }
    /// Whether the staged app satisfies the running app's identity. Required,
    /// with no default: a validator made without one used to accept any
    /// identity. `running()` builds it from the app that is running.
    var satisfiesRunningIdentity: @Sendable (URL) -> Bool

    static func running() -> BundleUpdateValidator {
        BundleUpdateValidator(
            runningVersion: ProductIdentity.version,
            runningBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0",
            satisfiesRunningIdentity: runningIdentityCheck()
        )
    }

    func validate(_ app: URL, release: UpdateCheck.Release) async throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateValidationError.unreadable
        }
        guard info["CFBundleIdentifier"] as? String == ProductIdentity.bundleIdentifier else {
            throw UpdateValidationError.wrongIdentifier
        }
        guard let version = info["CFBundleShortVersionString"] as? String, version == release.version else {
            throw UpdateValidationError.wrongVersion
        }
        guard UpdateCheck.isNewer(version, than: runningVersion) else { throw UpdateValidationError.notNewer }
        guard let build = (info["CFBundleVersion"] as? String).flatMap({ Int($0) }),
              let running = Int(runningBuild), build > running
        else { throw UpdateValidationError.buildNotNewer }
        guard codeIsIntact(app) else { throw UpdateValidationError.signatureInvalid }
        guard satisfiesRunningIdentity(app) else { throw UpdateValidationError.identityChanged }
    }

    /// `SecStaticCodeCheckValidityWithErrors` with strict validation, every
    /// architecture and nested code: the helper library included.
    static func codeSignatureIsIntact(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
    }

    // MARK: Identity

    /// The check for the app that is running. It fails closed: an app whose
    /// code cannot even be read is not known to be ad-hoc, so it is held to a
    /// requirement it cannot produce, and the update is the download page.
    static func runningIdentityCheck() -> @Sendable (URL) -> Bool {
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode
        else { return { _ in false } }
        return identityCheck(for: staticCode)
    }

    /// Whether the code is ad-hoc: its signing information says so, in the flags
    /// (`SecCodeSignatureFlags.adhoc`). Not a guess from the text of a requirement.
    /// Information that cannot be read answers nil, which is not ad-hoc.
    static func isAdHoc(_ code: SecStaticCode) -> Bool? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32
        else { return nil }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// The check for the app whose code is `staticCode`.
    static func identityCheck(for staticCode: SecStaticCode) -> @Sendable (URL) -> Bool {
        var requirement: SecRequirement?
        var text: CFString?
        var requirementText: String?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
           SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text {
            requirementText = text as String
        }
        return identityCheck(adHoc: isAdHoc(staticCode) ?? false, requirementText: requirementText)
    }

    /// The decision. An ad-hoc running app has no identity to keep and accepts
    /// any valid signature. Any other running app is held to its designated
    /// requirement, and if that cannot be read nothing satisfies it.
    static func identityCheck(adHoc: Bool, requirementText: String?) -> @Sendable (URL) -> Bool {
        if adHoc { return { _ in true } }
        guard let requirementText else { return { _ in false } }
        return identityCheck(requirementText: requirementText)
    }

    /// The check that a staged app satisfies `requirementText`.
    static func identityCheck(requirementText: String) -> @Sendable (URL) -> Bool {
        { app in
            var requirement: SecRequirement?
            var code: SecStaticCode?
            guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement,
                  SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code
            else { return false }
            return SecStaticCodeCheckValidityWithErrors(code, [], requirement, nil) == errSecSuccess
        }
    }
}

// MARK: - Swap

/// Puts the staged copy where the installed app is, and never leaves nothing.
///
/// The swap is `renamex_np(staged, installed, RENAME_SWAP)`: one atomic call
/// that exchanges the two on APFS and HFS+, so there is no instant at which the
/// installed path holds nothing. Afterwards the staged path holds the old app,
/// which is removed. Where the volume cannot swap (`ENOTSUP`, `EINVAL`) it falls
/// back to `replaceItemAt`, which is not atomic: it can fail with the original
/// already moved aside. So after any throw there, if the installed path is
/// missing, the original is moved back from where the error says it went
/// (`NSFileOriginalItemLocationKey`, then the other places an error names), and
/// the error is rethrown either way.
///
/// The three system calls are properties so a test can force each to fail
/// against real folders.
struct FileManagerSwapper: UpdateSwapping {
    /// 0 on success, else the errno.
    var swap: (_ staged: URL, _ installed: URL) -> Int32 = { staged, installed in
        renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }
    var replace: (_ installed: URL, _ staged: URL) throws -> Void = { installed, staged in
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged, backupItemName: nil, options: [])
    }
    var move: (_ from: URL, _ to: URL) throws -> Void = { from, to in
        try FileManager.default.moveItem(at: from, to: to)
    }

    func replace(installed: URL, with staged: URL) throws {
        let code = swap(staged, installed)
        if code == 0 {
            // The staged path now holds the old app. It was only going to be
            // removed with the staging folder anyway.
            try? FileManager.default.removeItem(at: staged)
            return
        }
        guard code == ENOTSUP || code == EINVAL else {
            // Atomic: nothing moved.
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            try replace(installed, staged)
        } catch {
            switch restore(installed: installed, staged: staged, after: error) {
            case .originalBack, .untouched: throw error
            case .stagedInPlace: return          // the validated update is what is installed
            case .nothingInPlace: throw error
            }
        }
    }

    private enum Restored {
        /// The installed path never lost its app.
        case untouched
        /// The original was found and moved back; the update did not happen.
        case originalBack
        /// The original could not be put back, so the staged, already
        /// validated, copy was moved into place instead: the update happened.
        case stagedInPlace
        /// Nothing could be put in place. The installed path is empty, and the
        /// staged copy is left exactly where it is.
        case nothingInPlace
    }

    /// After a failed replace, makes sure the installed path holds an app. The
    /// original goes back if the error says where it went; failing that, the
    /// staged copy (already validated) goes into place; failing that, nothing is
    /// deleted, the path of the staged copy is logged, and the installer, seeing
    /// the installed path empty, leaves the staging folder where it is.
    ///
    /// The staged copy is never a candidate for being the *original*, however
    /// the error names it: it is moved into place only as itself, on its own step.
    private func restore(installed: URL, staged: URL, after error: Error) -> Restored {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: installed.path) else { return .untouched }
        let skip = [installed, staged].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        for candidate in Self.candidates(in: error)
        where !skip.contains(candidate.resolvingSymlinksInPath().standardizedFileURL.path) && fm.fileExists(atPath: candidate.path) {
            do {
                try move(candidate, installed)
                Log.updates.notice("update: the original app was put back after a failed replace")
                return .originalBack
            } catch {
                continue
            }
        }
        if fm.fileExists(atPath: staged.path) {
            do {
                try move(staged, installed)
                Log.updates.notice("update: the original could not be put back, so the validated update was moved into place")
                return .stagedInPlace
            } catch {}
        }
        Log.updates.error("update: nothing is at the installed path; the staged copy is at \(staged.path, privacy: .public)")
        return .nothingInPlace
    }

    /// `NSFileOriginalItemLocationKey`, which Foundation does not export to Swift.
    static let originalItemLocationKey = "NSFileOriginalItemLocationKey"

    /// Where an error says the original went, most specific first.
    static func candidates(in error: Error) -> [URL] {
        var urls: [URL] = []
        func collect(_ error: NSError) {
            for key in [originalItemLocationKey, NSURLErrorKey, NSFilePathErrorKey] {
                if let url = error.userInfo[key] as? URL { urls.append(url) }
                else if let path = error.userInfo[key] as? String { urls.append(URL(fileURLWithPath: path)) }
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { collect(underlying) }
        }
        collect(error as NSError)
        return urls
    }
}

// MARK: - Relaunch

/// Starts the replaced app after this one has quit.
///
/// A shell waits until this process id is gone and then `exec`s `open` on the
/// installed path. The path and the id are *arguments* to the script (`$1`,
/// `$2`), never interpolated into it, so no character in an path can change what
/// runs. The shell has nothing on its stdin, stdout or stderr and nothing waits
/// for it; then the app quits the way Quit does: `terminate`, which stops the
/// media helper by closing its stdin and does not wait on anything of ours.
///
/// If the shell cannot be started Isla does **not** quit and says so (`false`):
/// quitting would leave nothing running to open the new copy, and a person who
/// pressed Update Now would find Isla gone. The panel then asks them to quit and
/// open it again.
@MainActor
struct ShellRelauncher: UpdateRelaunching {
    static let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#

    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// The shell. A seam only so a test can start something that ignores its
    /// arguments instead of the real one, which would run `open`.
    var shell = "/bin/sh"

    static func arguments(processID: Int32, installed: URL) -> [String] {
        ["-c", script, "sh", String(processID), installed.path]
    }

    @discardableResult
    func relaunch(installed: URL, processID: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = Self.arguments(processID: processID, installed: installed)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.updates.error("update: could not start the relaunch")
            return false
        }
        terminate()
        return true
    }
}

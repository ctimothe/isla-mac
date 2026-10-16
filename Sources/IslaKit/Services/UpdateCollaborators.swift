import AppKit
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
    var configuration: @Sendable () -> URLSessionConfiguration = { PrivateNetwork.makeConfiguration() }

    func download(
        from url: URL, into folder: URL, as fileName: String, expectedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let destination = folder.appendingPathComponent(fileName)
        let transfer = Transfer(destination: destination, expectedBytes: expectedBytes, progress: progress)
        let configuration = configuration()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
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
/// deadline after which it is ended.
enum UpdateTool {
    struct Result {
        let status: Int32
        let output: Data
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus, output: output))
            }
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
}

/// `hdiutil attach` read-only, not browsable, not opened in the Finder, with the
/// image's own checksum pass skipped (the signature already covers every byte)
/// and the mount point chosen by hdiutil under the run's own scratch folder.
struct HdiutilDiskImage: UpdateDiskImaging {
    static let hdiutil = "/usr/bin/hdiutil"

    static func attachArguments(image: URL, scratch: URL) -> [String] {
        ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountrandom", scratch.path, "-plist", image.path]
    }

    func attach(_ image: URL, scratch: URL) async throws -> URL {
        guard let result = await UpdateTool.run(Self.hdiutil, Self.attachArguments(image: image, scratch: scratch)),
              result.status == 0
        else { throw UpdateImageError.attachFailed }
        let mounts = Self.mountPoints(in: result.output)
        // Anything mounted is detached before this gives up, so a refusal
        // never leaves a volume behind.
        guard mounts.count == 1, let mount = mounts.first else {
            for mount in mounts { await detach(mount) }
            throw mounts.isEmpty ? UpdateImageError.noMountPoint : UpdateImageError.oneVolumeExpected
        }
        return mount
    }

    func detach(_ mountPoint: URL) async {
        if let result = await UpdateTool.run(Self.hdiutil, ["detach", "-force", mountPoint.path], timeout: 60), result.status == 0 { return }
        Log.updates.error("update: the disk image would not detach")
    }

    /// The mount points in `hdiutil attach -plist` output: every entry of
    /// `system-entities` that has one.
    static func mountPoints(in plist: Data) -> [URL] {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let root = object as? [String: Any], let entities = root["system-entities"] as? [[String: Any]]
        else { return [] }
        return entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
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
        guard let result = await UpdateTool.run("/usr/bin/ditto", [source.path, destination.path]), result.status == 0 else {
            throw UpdateImageError.stageFailed
        }
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
}

/// Judges the staged copy, and only the staged copy: whatever the image said,
/// this is what would be run.
///
/// It is Isla (`com.ctimothe.isla`), it is the version the release advertised,
/// that version is newer than the running one and its build number is greater,
/// and its code signature is intact — every file, every architecture, nested
/// code included. It does **not** require the same signing identity as the
/// running app. A changed identity is allowed on purpose, as in Sparkle, which
/// accepts a rotated certificate when the update's own signature holds: here
/// that is the Ed25519 signature over the image, which was verified before the
/// image was mounted, and demanding the old identity would make a certificate
/// change impossible to ship.
struct BundleUpdateValidator: UpdateValidating {
    var runningVersion: String
    var runningBuild: String
    var codeIsIntact: @Sendable (URL) -> Bool = { BundleUpdateValidator.codeSignatureIsIntact($0) }

    static func running() -> BundleUpdateValidator {
        BundleUpdateValidator(
            runningVersion: ProductIdentity.version,
            runningBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
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
    }

    /// `SecStaticCodeCheckValidityWithErrors` with strict validation, every
    /// architecture and nested code: the helper library included.
    static func codeSignatureIsIntact(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
    }
}

// MARK: - Swap

/// One `replaceItemAt`, which swaps the two on the same volume and removes the
/// old one afterwards. No backup name: a failure leaves the installed app as it
/// was, and a success has nothing to go back to.
struct FileManagerSwapper: UpdateSwapping {
    func replace(installed: URL, with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged, backupItemName: nil, options: [])
    }
}

// MARK: - Relaunch

/// Starts the replaced app after this one has quit.
///
/// A shell waits until this process id is gone and then `exec`s `open` on the
/// installed path. The path and the id are *arguments* to the script (`$1`,
/// `$2`), never interpolated into it, so no character in a path can change what
/// runs. The shell has nothing on its stdin, stdout or stderr and nothing waits
/// for it; then the app quits the way Quit does: `terminate`, which stops the
/// media helper by closing its stdin and does not wait on anything of ours.
///
/// If the shell cannot be started the app quits anyway: the new copy is already
/// in place, and the person opens it by hand.
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

    func relaunch(installed: URL, processID: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = Self.arguments(processID: processID, installed: installed)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { Log.updates.error("update: could not start the relaunch") }
        terminate()
    }
}

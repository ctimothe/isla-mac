import AppKit
import Combine

// MARK: - Seams
//
// Every collaborator of the installer is a protocol with one production
// implementation (`UpdateCollaborators.swift`) and a fake in the tests. The
// installer is the order of the steps and the cleanup after them; what each step
// does to the disk, the network and the system is behind these, so the whole
// sequence — and every way it can stop half way — is played out in a test
// without a download, a mount or an app being replaced.

/// Downloads one file into `folder` as `fileName` and returns where it landed.
/// `expectedBytes` is the advertised size: a transfer that passes it is stopped.
/// Progress is the bytes received so far. Throws `CancellationError` when the
/// task is cancelled, and removes any partial file on every failure.
protocol UpdateDownloading: Sendable {
    func download(
        from url: URL, into folder: URL, as fileName: String, expectedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL
}

/// Whether the signature is valid for the bytes of the file on disk.
protocol UpdateVerifying: Sendable {
    func isValid(signatureBase64: String, fileURL: URL) async -> Bool
}

/// Attaches a disk image and detaches it again. `attach` returns the mount
/// point; `detach` never throws, because it runs on the way out of a failure.
protocol UpdateDiskImaging: Sendable {
    func attach(_ image: URL, scratch: URL) async throws -> URL
    func detach(_ mountPoint: URL) async
}

/// Copies the one `Isla.app` at the root of a mounted volume into
/// `stagingFolder` and returns the copy.
protocol UpdateStaging: Sendable {
    func stage(volume: URL, into stagingFolder: URL) async throws -> URL
}

/// Decides whether the staged copy is a valid Isla update; throws
/// `UpdateValidationError` when it is not.
protocol UpdateValidating: Sendable {
    func validate(_ app: URL, release: UpdateCheck.Release) async throws
}

/// Puts the staged copy where the installed app is. Any failure leaves the
/// installed app as it was.
protocol UpdateSwapping {
    func replace(installed: URL, with staged: URL) throws
}

/// Starts the new copy once this process has gone, and ends this process.
@MainActor
protocol UpdateRelaunching {
    func relaunch(installed: URL, processID: Int32)
}

/// What the installer asks of the Mac it runs on, before it does anything.
struct UpdateEnvironment {
    /// The running app: `Bundle.main.bundleURL`.
    var installedURL: URL
    /// The base64 public key of this build, if it was built with one.
    var publicKey: String?
    var processID: Int32
    /// Bytes available for important use on the volume of `url`, nil if unknown.
    var availableCapacity: (URL) -> Int64?
    var isWritable: (URL) -> Bool
    /// Where the download and the mount live, whose volume the free-space
    /// check also looks at.
    var scratchRoot: URL
    /// A fresh private folder under `scratchRoot` for one run's download and mount.
    var makeScratchFolder: () throws -> URL

    static func live() -> UpdateEnvironment {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return UpdateEnvironment(
            installedURL: Bundle.main.bundleURL,
            publicKey: UpdateSignature.bundledPublicKey,
            processID: ProcessInfo.processInfo.processIdentifier,
            availableCapacity: { url in
                (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
            },
            isWritable: { FileManager.default.isWritableFile(atPath: $0.path) },
            scratchRoot: scratch,
            makeScratchFolder: {
                // The user's own temporary folder, not the system's
                // item-replacement area: a volume mounted under
                // `TemporaryItems` answers "Operation not permitted" to anyone
                // who lists it, which the first real run of this found. The
                // staged copy, the only thing that has to be on the install
                // volume, is made beside the installed app, not here.
                let folder = scratch.appendingPathComponent("isla-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return folder
            }
        )
    }
}

// MARK: - The installer

/// Update Now: downloads the release, checks it, replaces this app with it and
/// restarts, only when the person presses the button.
///
/// The order is the design, and it is the order of the risks:
///
/// 1. **Before anything is fetched** the installer decides whether it can finish
///    at all — where the app lives, whether its folder is writable, whether this
///    build carries a key, whether the release names an image and a signature,
///    whether the disk has room — so nobody downloads ten megabytes to hear no.
/// 2. **The signature is fetched first** (a kilobyte), then the image, and the
///    image's size must be the one advertised.
/// 3. **The signature is verified before the image is mounted.** A disk image
///    parser is attack surface; an image that is not Isla's is never attached.
/// 4. **Only the staged copy is judged.** The image is mounted read-only, the
///    app is copied beside the installed one (same volume, so the swap is a
///    rename), the image is detached, and the validator looks at the copy, not
///    at the image, so nothing can change between the check and the use.
/// 5. **The swap is one `replaceItemAt`.** A failure leaves the installed app
///    untouched.
/// 6. **Everything the run made is removed on every path**, including the
///    ones that end the process: the cleanup runs *before* the relaunch,
///    because `terminate` does not return.
///
/// One install runs at a time. Nothing starts it but `install(_:)`, and the
/// only caller is the Update Now button: the daily check only reports.
@MainActor
final class UpdateInstaller: ObservableObject {
    static var shared: UpdateInstaller { sharedOverride ?? live }
    /// Stands in front of the real one, for the visual lab, which must draw
    /// every state without an update happening.
    static var sharedOverride: UpdateInstaller?
    private static let live = UpdateInstaller()

    enum Failure: Error, Equatable {
        case offline
        case signature
        case invalidUpdate
        case diskSpace
        case cannotReplace
        /// Pressing Cancel while it downloads. Not shown as a failure: the
        /// installer returns to `idle` and the release is on offer again.
        case cancelled
    }

    /// Why Update Now is not offered, decided before any download.
    enum ManualReason: Equatable {
        case translocated, mountedVolume, notAnApp, notWritable
        case noPublicKey, noImage, noSignature

        /// The app's place is the problem, as opposed to this release or this
        /// build; the panel words the two differently.
        var isLocation: Bool {
            switch self {
            case .translocated, .mountedVolume, .notAnApp, .notWritable: return true
            case .noPublicKey, .noImage, .noSignature: return false
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case relaunching
        case failed(Failure)
        case manualOnly(ManualReason)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing, .relaunching: return true
            case .idle, .failed, .manualOnly: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// The release the installer is working on or last worked on, so the panel
    /// keeps showing it even if a later check finds a different one.
    @Published private(set) var release: UpdateCheck.Release?

    /// Free space on the install volume the image's size is multiplied by:
    /// the download, the staged copy, and room to work.
    static let spaceFactor = 2.5
    nonisolated static let stagingPrefix = ".Isla-update-"
    nonisolated static let imageFileName = "Isla.dmg"
    nonisolated static let signatureFileName = "Isla.dmg.sig"

    private let environment: UpdateEnvironment
    private let downloader: UpdateDownloading
    private let verifier: UpdateVerifying
    private let diskImage: UpdateDiskImaging
    private let stager: UpdateStaging
    private let validator: UpdateValidating
    private let swapper: UpdateSwapping
    private let relauncher: UpdateRelaunching
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        environment: UpdateEnvironment = .live(),
        downloader: UpdateDownloading = URLSessionUpdateDownloader(),
        verifier: UpdateVerifying? = nil,
        diskImage: UpdateDiskImaging = HdiutilDiskImage(),
        stager: UpdateStaging = DittoUpdateStager(),
        validator: UpdateValidating? = nil,
        swapper: UpdateSwapping = FileManagerSwapper(),
        relauncher: UpdateRelaunching? = nil
    ) {
        self.environment = environment
        self.downloader = downloader
        self.verifier = verifier ?? Ed25519UpdateVerifier(publicKey: environment.publicKey ?? "")
        self.diskImage = diskImage
        self.stager = stager
        self.validator = validator ?? BundleUpdateValidator.running()
        self.swapper = swapper
        self.relauncher = relauncher ?? ShellRelauncher()
    }

    // MARK: Deciding

    /// Why this release cannot be installed from here, or nil when it can.
    /// Pure of side effects, so the panel asks it on every draw.
    func manualReason(for release: UpdateCheck.Release) -> ManualReason? {
        let installed = environment.installedURL
        let path = installed.path
        if path.contains("/AppTranslocation/") { return .translocated }
        // A disk image or a network share: the copy would be thrown away on
        // eject, and the volume may be read-only.
        if path.hasPrefix("/Volumes/") { return .mountedVolume }
        // `swift run` and the tests have no bundle to replace.
        if installed.pathExtension != "app" { return .notAnApp }
        if !environment.isWritable(installed.deletingLastPathComponent()) { return .notWritable }
        if !UpdateSignature.isUsablePublicKey(environment.publicKey) { return .noPublicKey }
        guard let image = release.dmg,
              UpdateCheck.trustedAsset(name: image.name, url: image.url, size: image.size, version: release.version, kind: .dmg) != nil
        else { return .noImage }
        guard let signature = release.signature,
              UpdateCheck.trustedAsset(name: signature.name, url: signature.url, size: signature.size, version: release.version, kind: .signature) != nil
        else { return .noSignature }
        return nil
    }

    // MARK: Running

    /// Starts installing `release`. Ignored while an install is running.
    func install(_ release: UpdateCheck.Release) {
        guard !phase.isBusy else { return }
        self.release = release
        if let reason = manualReason(for: release) {
            Log.updates.notice("update: not installable here, \(String(describing: reason), privacy: .public)")
            phase = .manualOnly(reason)
            return
        }
        guard let image = release.dmg, let signature = release.signature else { return }
        let parent = environment.installedURL.deletingLastPathComponent()
        // Both volumes: the download and the mount are in the temporary folder,
        // the staged copy is beside the app. Unknown free space is not proof of
        // too little.
        for volume in [parent, environment.scratchRoot] {
            if let free = environment.availableCapacity(volume), Double(free) < Self.spaceFactor * Double(image.size) {
                Log.updates.notice("update: not enough space, \(free, privacy: .public) free for \(image.size, privacy: .public)")
                phase = .failed(.diskSpace)
                return
            }
        }
        phase = .downloading(received: 0, total: image.size)
        generation += 1
        let id = generation
        task = Task { [weak self] in
            await self?.perform(release, image: image, signature: signature, generation: id)
        }
    }

    /// Cancel is offered while the download runs, and only then.
    func cancel() {
        guard case .downloading = phase else { return }
        task?.cancel()
    }

    /// Clears a failure or a manual-only verdict, back to offering the release.
    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    /// Shows a state without being in it, for the visual lab, which draws every
    /// card the installer can produce without a download. Does nothing outside a
    /// test process.
    func presentForTests(_ phase: Phase, release: UpdateCheck.Release?) {
        guard PlayerBridge.isRunningTests else { return }
        self.release = release
        self.phase = phase
    }

    private func progressed(_ received: Int64, generation id: Int) {
        guard id == generation, case .downloading(let old, let total) = phase, received > old else { return }
        phase = .downloading(received: min(received, total), total: total)
    }

    /// Everything the run made on disk, removed in one place.
    private final class Disposables {
        private var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
        func run() {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            urls.removeAll()
        }
    }

    private func perform(
        _ release: UpdateCheck.Release, image: UpdateCheck.Release.Asset, signature: UpdateCheck.Release.Asset,
        generation id: Int
    ) async {
        let disposables = Disposables()
        defer { disposables.run() }
        do {
            let installed = environment.installedURL
            let parent = installed.deletingLastPathComponent()
            Self.sweepStaleStaging(in: parent)

            let scratch = try step(.cannotReplace) { try environment.makeScratchFolder() }
            disposables.add(scratch)
            // Named before it exists, so a failure half way through staging
            // still has its folder removed.
            let staging = parent.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
            disposables.add(staging)

            // The signature first: a kilobyte, and it fails a bad release
            // before ten megabytes are fetched.
            let signatureFile = try await download(signature, into: scratch, as: Self.signatureFileName)
            guard Self.size(of: signatureFile) == signature.size,
                  let signatureData = try? Data(contentsOf: signatureFile)
            else { throw Failure.signature }
            let signatureText = String(decoding: signatureData, as: UTF8.self)

            let imageFile = try await download(image, into: scratch, as: Self.imageFileName) { [weak self] received in
                Task { @MainActor in self?.progressed(received, generation: id) }
            }
            // A cancel that arrived as the last byte did stops here, not
            // half way through a mount.
            if Task.isCancelled { throw Failure.cancelled }
            guard Self.size(of: imageFile) == image.size else { throw Failure.signature }

            phase = .verifying
            guard await verifier.isValid(signatureBase64: signatureText, fileURL: imageFile) else {
                Log.updates.error("update: the download did not match the signature, deleted")
                throw Failure.signature
            }

            phase = .installing
            let mountPoint = try await attempt(.invalidUpdate) {
                try await diskImage.attach(imageFile, scratch: scratch)
            }
            let staged: URL
            do {
                staged = try await attempt(.invalidUpdate) {
                    try await stager.stage(volume: mountPoint, into: staging)
                }
            } catch {
                await diskImage.detach(mountPoint)
                throw error
            }
            await diskImage.detach(mountPoint)

            try await attempt(.invalidUpdate) { try await validator.validate(staged, release: release) }
            try step(.cannotReplace) { try swapper.replace(installed: installed, with: staged) }

            phase = .relaunching
            // Before the relaunch, which may never return: the process ends in
            // it, and a defer would not run.
            disposables.run()
            relauncher.relaunch(installed: installed, processID: environment.processID)
        } catch {
            let failure = Self.failure(from: error, default: .offline)
            Log.updates.error("update stopped: \(String(describing: failure), privacy: .public)")
            phase = failure == .cancelled ? .idle : .failed(failure)
        }
    }

    private func download(
        _ asset: UpdateCheck.Release.Asset, into folder: URL, as fileName: String,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        try await attempt(.offline) {
            try await downloader.download(
                from: asset.url, into: folder, as: fileName, expectedBytes: asset.size, progress: progress
            )
        }
    }

    // MARK: Helpers

    /// Runs a step and turns whatever it throws into a `Failure`: its own if it
    /// is one, a cancellation as `cancelled`, anything else as `fallback`.
    private func attempt<T>(_ fallback: Failure, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.failure(from: error, default: fallback) }
    }

    private func step<T>(_ fallback: Failure, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Self.failure(from: error, default: fallback) }
    }

    nonisolated static func failure(from error: Error, default fallback: Failure) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return fallback
    }

    nonisolated static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    /// A staging folder a crash or a power cut left beside the app. Only
    /// folders with Isla's own prefix, and only here, where nothing else of
    /// Isla's can be using one: an install is one at a time.
    nonisolated static func sweepStaleStaging(in parent: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(stagingPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }
}

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

/// Attaches a disk image and detaches it again. `attach` returns the mount; if
/// it fails it has already detached anything it attached, or throws
/// `UpdateImageError.stillAttached`. `detach` never throws, because it runs on
/// the way out of a failure, and says whether the volume is gone.
protocol UpdateDiskImaging: Sendable {
    func attach(_ image: URL, scratch: URL) async throws -> UpdateMount
    func detach(_ mount: UpdateMount) async -> Bool
    /// Looks the image up once more by its file and detaches whatever is still
    /// attached from it: a mount that landed late, after an attach that was
    /// killed. True when nothing is left attached.
    func cleanUp(image: URL) async -> Bool
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
/// Returns false, and does *not* end this process, when it could not start
/// anything to open the new copy.
@MainActor
protocol UpdateRelaunching {
    @discardableResult
    func relaunch(installed: URL, processID: Int32) -> Bool
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
    /// Whether the installed bundle is owned by the current user and can be
    /// removed by them: a swap that needs another account's rights would fail
    /// after the whole download.
    var canReplace: (URL) -> Bool
    /// Whether anything under `url` is a mounted volume, which must never be
    /// deleted into.
    var containsMount: (URL) -> Bool
    /// Where the download and the mount live, whose volume the free-space
    /// check also looks at.
    var scratchRoot: URL
    /// A fresh private folder under `scratchRoot` for one run's download and mount.
    var makeScratchFolder: () throws -> URL
    /// The rehearsal folder (`DI_UPDATE_REHEARSAL`), whose files the assets may be.
    var rehearsal: URL? = nil

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
            canReplace: { UpdateInstaller.currentUserCanReplace($0) },
            containsMount: { UpdateInstaller.directoryContainsMount($0) },
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
            },
            rehearsal: DebugTrail.updateRehearsal
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
///    at all — where the app lives, whether its folder is writable and the app
///    is the user's to replace, whether this build carries a key, whether the
///    release names an image and a signature, whether the disk has room — so
///    nobody downloads ten megabytes to hear no.
/// 2. **The signature is fetched first** (a kilobyte), then the image, and the
///    image's size must be the one advertised.
/// 3. **The signature is verified before the image is mounted.** A disk image
///    parser is attack surface; an image that is not Isla's is never attached.
/// 4. **Only the staged copy is judged.** The image is mounted read-only, the
///    app is copied beside the installed one (same volume, so the swap is a
///    rename), the image is detached, and the validator looks at the copy, not
///    at the image, so nothing can change between the check and the use. An
///    image that cannot be detached stops the install before the swap.
/// 5. **The swap is one atomic exchange** (`FileManagerSwapper`), and a failure
///    leaves the installed app in place.
/// 6. **Everything the run made is removed on every path**, including the
///    ones that end the process: the cleanup runs *before* the relaunch,
///    because `terminate` does not return. Nothing is ever deleted into a
///    volume that is still mounted.
/// 7. **The installing phase has a ceiling** (`installTimeout`): a hung tool
///    ends in a failure with Try Again, not in a card that never changes.
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
        /// The image would not open or would not let go: a tool that hung past
        /// the ceiling, or a volume that could not be detached.
        case cannotOpen
        /// Pressing Cancel while it downloads. Not shown as a failure: the
        /// installer returns to `idle` and the release is on offer again.
        case cancelled
    }

    /// Why Update Now is not offered.
    enum ManualReason: Equatable {
        case translocated, mountedVolume, notAnApp, notWritable
        /// The installed bundle belongs to another account, or cannot be removed
        /// by this one.
        case notOwned
        case noPublicKey, noImage, noSignature
        /// The update is validly signed by a different identity than the running
        /// app's, which would cost it its permissions. Decided only after the
        /// download, when the staged copy can be looked at.
        case identityChanged

        /// The app's place is the problem, as opposed to this release or this
        /// build; the panel words the two differently.
        var isLocation: Bool {
            switch self {
            case .translocated, .mountedVolume, .notAnApp, .notWritable, .notOwned: return true
            case .noPublicKey, .noImage, .noSignature, .identityChanged: return false
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case relaunching
        /// The new copy is in place and could not be started: the person is
        /// asked to quit and open Isla again. Final until Isla quits.
        case restartNeeded
        case failed(Failure)
        case manualOnly(ManualReason)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing, .relaunching, .restartNeeded: return true
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
    nonisolated static let spaceFactor = 2.5
    nonisolated static let stagingPrefix = ".Isla-update-"
    nonisolated static let imageFileName = "Isla.dmg"
    nonisolated static let signatureFileName = "Isla.dmg.sig"
    /// The ceiling on the installing phase, mount to swap.
    nonisolated static let defaultInstallTimeout: TimeInterval = 120

    private let environment: UpdateEnvironment
    private let downloader: UpdateDownloading
    private let verifier: UpdateVerifying
    private let diskImage: UpdateDiskImaging
    private let stager: UpdateStaging
    private let validator: UpdateValidating
    private let swapper: UpdateSwapping
    private let relauncher: UpdateRelaunching
    private let installTimeout: TimeInterval
    /// What a sweep asks before it removes anything. The process-wide one in the
    /// app, because the launch sweep is static; a test gives its own.
    private let stagingActivity: StagingActivity
    private var task: Task<Void, Never>?
    private var generation = 0
    private var subscription: AnyCancellable?

    init(
        environment: UpdateEnvironment = .live(),
        downloader: UpdateDownloading? = nil,
        verifier: UpdateVerifying? = nil,
        diskImage: UpdateDiskImaging = HdiutilDiskImage(),
        stager: UpdateStaging = DittoUpdateStager(),
        validator: UpdateValidating? = nil,
        swapper: UpdateSwapping = FileManagerSwapper(),
        relauncher: UpdateRelaunching? = nil,
        installTimeout: TimeInterval = UpdateInstaller.defaultInstallTimeout,
        stagingActivity: StagingActivity = UpdateInstaller.stagingActivity
    ) {
        self.stagingActivity = stagingActivity
        self.environment = environment
        self.downloader = downloader ?? URLSessionUpdateDownloader(rehearsal: environment.rehearsal)
        self.verifier = verifier ?? Ed25519UpdateVerifier(publicKey: environment.publicKey ?? "")
        self.diskImage = diskImage
        self.stager = stager
        self.validator = validator ?? BundleUpdateValidator.running()
        self.swapper = swapper
        self.relauncher = relauncher ?? ShellRelauncher()
        self.installTimeout = installTimeout
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
        if !environment.canReplace(installed) { return .notOwned }
        if !UpdateSignature.isUsablePublicKey(environment.publicKey) { return .noPublicKey }
        guard let image = release.dmg,
              UpdateCheck.trustedAsset(name: image.name, url: image.url, size: image.size, version: release.version, kind: .dmg, rehearsal: environment.rehearsal) != nil
        else { return .noImage }
        guard let signature = release.signature,
              UpdateCheck.trustedAsset(name: signature.name, url: signature.url, size: signature.size, version: release.version, kind: .signature, rehearsal: environment.rehearsal) != nil
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
        switch phase {
        case .failed, .manualOnly: phase = .idle
        case .idle, .downloading, .verifying, .installing, .relaunching, .restartNeeded: break
        }
    }

    /// Follows a check. A failed or refused install belongs to the release it
    /// tried, so a check that finds Isla up to date, or finds a different
    /// release, ends it: Try Again must never install a release that is no
    /// longer the one on offer. The same release again keeps it.
    func observe(_ check: UpdateCheck) {
        subscription = check.$state.sink { [weak self] state in
            Task { @MainActor in self?.settle(with: state) }
        }
    }

    func settle(with state: UpdateCheck.State) {
        switch phase {
        case .failed, .manualOnly: break
        default: return
        }
        switch state {
        case .upToDate: reset()
        case .available(let found) where found.version != release?.version: reset()
        default: break
        }
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

    /// Everything the run made on disk, removed in one place, and never into a
    /// mounted volume: a folder with a volume under it is left, and logged.
    ///
    /// The staging folder is also left, and its path logged, while the installed
    /// path holds nothing: if a swap failed half way it may hold the only good
    /// copy of Isla there is.
    private final class Disposables {
        private var urls: [(url: URL, needsInstalled: Bool)] = []
        private let containsMount: (URL) -> Bool
        private let installedExists: () -> Bool
        init(containsMount: @escaping (URL) -> Bool, installedExists: @escaping () -> Bool) {
            self.containsMount = containsMount
            self.installedExists = installedExists
        }
        func add(_ url: URL, needsInstalled: Bool = false) { urls.append((url, needsInstalled)) }
        func run() {
            for (url, needsInstalled) in urls {
                if needsInstalled, !installedExists() {
                    Log.updates.error("update: the installed app is missing, so the staged copy is left at \(url.path, privacy: .public)")
                    continue
                }
                if containsMount(url) {
                    Log.updates.error("update: a folder was left because a volume is still mounted in it")
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            }
            urls.removeAll()
        }
    }

    private func perform(
        _ release: UpdateCheck.Release, image: UpdateCheck.Release.Asset, signature: UpdateCheck.Release.Asset,
        generation id: Int
    ) async {
        let installed = environment.installedURL
        let ceiling = Ceiling()
        var watchdog: Task<Void, Never>?
        var attached = false
        var scratchImage: URL?
        var stagingMarked = false
        // Declared before the cleanup below, so it runs after it: the cleanup
        // finishes while the guard is still held, and no sweep can meet it.
        let activity = stagingActivity
        defer {
            watchdog?.cancel()
            if stagingMarked { activity.end() }
        }
        let disposables = Disposables(
            containsMount: environment.containsMount,
            installedExists: { FileManager.default.fileExists(atPath: installed.path) }
        )
        defer { disposables.run() }
        do {
            let parent = installed.deletingLastPathComponent()
            // Named before anything else, so a failure half way through staging
            // still has its folder removed, and so the sweep below can be told
            // to leave it alone.
            let staging = parent.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
            disposables.add(staging, needsInstalled: true)
            // The sweep of what a lost run left runs to its end, off the main
            // actor, *before* this install makes its own folder, and is told
            // not to touch this one besides. It is never concurrent with the
            // staging, validating and swapping below (`stagingActivity`): a
            // sweep walking a folder while the swap moves it into place would
            // leave no app at all.
            await Task.detached(priority: .utility) {
                Self.sweepStaleStaging(in: parent, except: staging, installed: installed, ownerID: Self.ownerID, activity: activity)
            }.value

            let scratch = try step(.cannotReplace) { try environment.makeScratchFolder() }
            disposables.add(scratch)

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
            scratchImage = imageFile

            phase = .verifying
            guard await verifier.isValid(signatureBase64: signatureText, fileURL: imageFile) else {
                Log.updates.error("update: the download did not match the signature, deleted")
                throw Failure.signature
            }

            phase = .installing
            attached = true
            // From here to the swap a sweep must leave every staging folder be.
            activity.begin()
            stagingMarked = true
            // The ceiling on everything from the mount to the swap. It is one:
            // at the ceiling the card moves to the failure and Try Again is
            // offered, whatever the steps behind it are still doing, and the
            // cleanup they owe finishes in the background (every tool in it has
            // a short timeout of its own). It also cancels this task, which
            // ends the tool in flight; what a cancelled step throws is then read
            // as the ceiling, not as a cancel.
            let seconds = installTimeout
            let running = task
            watchdog = Task { [ceiling, weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                ceiling.fire()
                running?.cancel()
                if let self, self.generation == id, self.phase == .installing {
                    Log.updates.error("update: the installing phase hit its ceiling")
                    self.phase = .failed(.cannotOpen)
                }
            }

            let mount = try await attempt(.invalidUpdate, ceiling: ceiling) {
                try await diskImage.attach(imageFile, scratch: scratch)
            }
            let staged: URL
            do {
                staged = try await attempt(.invalidUpdate, ceiling: ceiling) {
                    try await stager.stage(volume: mount.mountPoint, into: staging)
                }
            } catch {
                // A volume that will not let go is the worse news.
                if !(await detach(mount)) { throw Failure.cannotOpen }
                throw error
            }
            // Detached before the staged copy is judged or swapped in; an image
            // that will not let go stops the install here.
            guard await detach(mount) else { throw Failure.cannotOpen }

            try await attempt(.invalidUpdate, ceiling: ceiling) { try await validator.validate(staged, release: release) }
            // The swap is not interruptible, so a ceiling that fired during
            // validation ends the install before it, never in the middle of it.
            if ceiling.fired { throw Failure.cannotOpen }
            try step(.cannotReplace) { try swapper.replace(installed: installed, with: staged) }
            watchdog?.cancel()

            phase = .relaunching
            // Before the relaunch, which may never return: the process ends in
            // it, and a defer would not run. The guard is let go after it.
            disposables.run()
            activity.end()
            stagingMarked = false
            if !relauncher.relaunch(installed: installed, processID: environment.processID) {
                // The new copy is in place; there is just nothing to open it.
                Log.updates.error("update: installed, but the relaunch could not start")
                phase = .restartNeeded
            }
        } catch {
            var failure = Self.failure(from: error, default: .offline)
            if ceiling.fired, failure == .cancelled || failure == .invalidUpdate { failure = .cannotOpen }
            if case UpdateImageError.stillAttached = error { failure = .cannotOpen }
            Log.updates.error("update stopped: \(String(describing: failure), privacy: .public)")
            // A run that was ended at its ceiling has already said so, and
            // everything since (a check that moved the card on, a person who
            // pressed Try Again) belongs to what came after: this run publishes
            // nothing more and only cleans up.
            if id == generation, !ceiling.fired {
                if case UpdateValidationError.identityChanged = error {
                    phase = .manualOnly(.identityChanged)
                } else {
                    phase = failure == .cancelled ? .idle : .failed(failure)
                }
            }
            // An attach that was killed can still mount late. Once more, by the
            // image's file, before its folder is deleted; and if it will not
            // let go, the folder is left (`Disposables` sees the volume). A
            // hdiutil that ignores even SIGKILL can still mount *after* this
            // look, and nothing here can reach that: the folder is deleted
            // unless a volume is seen in it.
            if attached {
                let diskImage = diskImage
                let imageURL = scratchImage
                if let imageURL, !(await UpdateTool.uncancellable { await diskImage.cleanUp(image: imageURL) }) {
                    Log.updates.error("update: an image was still attached after the install ended")
                }
            }
        }
    }

    /// Detaches in a task a cancelled install cannot end. If the volume is still
    /// there afterwards its folder is kept, not deleted into.
    private func detach(_ mount: UpdateMount) async -> Bool {
        let diskImage = diskImage
        let gone = await UpdateTool.uncancellable { await diskImage.detach(mount) }
        if !gone { Log.updates.error("update: the disk image is still attached; its folder is left alone") }
        return gone
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

    /// Whether the installing ceiling has been reached.
    private final class Ceiling: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false
        func fire() { lock.lock(); reached = true; lock.unlock() }
        var fired: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    }

    /// Runs a step and turns whatever it throws into a `Failure`: its own if it
    /// is one, a cancellation as `cancelled`, anything else as `fallback`. An
    /// `UpdateImageError.stillAttached` and an identity change pass through for
    /// `perform` to read.
    private func attempt<T>(_ fallback: Failure, ceiling: Ceiling? = nil, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            if case UpdateImageError.stillAttached = error { throw error }
            if case UpdateValidationError.identityChanged = error { throw error }
            throw Self.failure(from: error, default: fallback)
        }
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

    // MARK: Leftovers

    /// `.Isla-update-<UUID>`, exactly: the name this installer gives its staging
    /// folder and nothing a person or another program would.
    nonisolated static func isStagingFolderName(_ name: String) -> Bool {
        // Parsed, not pattern-matched: `$` in a regular expression also matches
        // before a trailing newline, and a name with one is not ours.
        guard name.hasPrefix(stagingPrefix) else { return false }
        let rest = String(name.dropFirst(stagingPrefix.count))
        return rest.utf8.count == 36 && UUID(uuidString: rest) != nil
    }

    /// The owner of a path, without following a link at the end of it.
    nonisolated static func ownerID(_ url: URL) -> UInt32? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_uid
    }

    /// Stale staging folders a crash or a power cut left beside the app: only
    /// real directories named exactly like one (`isStagingFolderName`), owned by
    /// the current user, and not `except` (the install under way).
    ///
    /// Never while the installed path is missing (`installed`, when given): a
    /// staging folder may then hold the only good copy of the app.
    nonisolated static func sweepStaleStaging(
        in parent: URL, except current: URL? = nil, installed: URL? = nil,
        ownerID owner: (URL) -> UInt32? = UpdateInstaller.ownerID, user: UInt32 = getuid(),
        activity: StagingActivity = UpdateInstaller.stagingActivity
    ) {
        let fm = FileManager.default
        if let installed, !fm.fileExists(atPath: installed.path) {
            Log.updates.error("update: the installed app is missing, so no staging folder is swept")
            return
        }
        guard !activity.isActive, let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where isStagingFolderName(name) {
            // Asked again for every folder: an install may have reached its
            // staging since the list was made, and its folder is on that list.
            guard !activity.isActive else { return }
            let url = parent.appendingPathComponent(name, isDirectory: true)
            guard url != current, owner(url) == user else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Whether an install is between mounting and swapping, process-wide: the
    /// launch sweep is static and has no installer to ask.
    final class StagingActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var depth = 0
        func begin() { lock.withLock { depth += 1 } }
        func end() { lock.withLock { depth = max(0, depth - 1) } }
        var isActive: Bool { lock.withLock { depth > 0 } }
    }
    nonisolated static let stagingActivity = StagingActivity()

    /// The sweep at launch, off the main thread: the folder beside the app is
    /// the one a crashed install used. Does nothing for an app that is not an
    /// installed bundle, or that runs from a place no install could have used.
    static func sweepAtLaunch(environment: UpdateEnvironment = .live()) {
        let installed = environment.installedURL
        guard installed.pathExtension == "app", !installed.path.hasPrefix("/Volumes/"),
              !installed.path.contains("/AppTranslocation/")
        else { return }
        let parent = installed.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async { sweepStaleStaging(in: parent, installed: installed) }
    }

    /// Whether the installed bundle is the current user's to replace: owned by
    /// them and removable by them.
    nonisolated static func currentUserCanReplace(_ url: URL) -> Bool {
        ownerID(url) == getuid() && FileManager.default.isDeletableFile(atPath: url.path)
    }

    /// Whether any direct child of `url` is on another device than `url`: a
    /// mount point under it. `-mountrandom` mounts directly under the scratch
    /// folder, so one level is the whole question.
    nonisolated static func directoryContainsMount(_ url: URL) -> Bool {
        var root = stat()
        guard lstat(url.path, &root) == 0 else { return false }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        for name in names {
            var child = stat()
            if lstat(url.appendingPathComponent(name).path, &child) == 0, child.st_dev != root.st_dev { return true }
        }
        return false
    }
}

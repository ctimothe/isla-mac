import XCTest
@testable import IslaKit

@MainActor
final class ScreenshotVaultTests: XCTestCase {
    func testCollisionCreatesNumberedPNGWithoutDeletingEitherFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        )
        let vault = ScreenshotVault(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // Saving writes off the main thread now, so the two are awaited in
        // turn — which is also the order the collision check depends on.
        let firstSaved = await vault.saved(Data([1]), at: date)
        let first = try XCTUnwrap(firstSaved)
        let secondSaved = await vault.saved(Data([2]), at: date)
        let second = try XCTUnwrap(secondSaved)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    /// The filename pattern must not be translatable: it is a `DateFormatter`
    /// format string, and a translation that dropped its quoting would either
    /// reinterpret the literal as format specifiers or put a path separator in
    /// a filename.
    func testStampIsIndependentOfLocalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ScreenshotVault(paths: AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        ))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = await vault.saved(Data([1]), at: date)
        let url = try XCTUnwrap(saved)
        let name = url.deletingPathExtension().lastPathComponent
        XCTAssertTrue(name.contains(" at "), "expected the fixed 'at' literal, got \(name)")
        XCTAssertEqual(name, "Screenshot \(expectedStamp(of: date))")

        // The part with teeth: neither the prefix nor the date pattern may be a
        // localization key. Asserting only on the produced name could not fail —
        // English's value was byte-identical to the literal — so this asserts on
        // the source of truth instead. Reverting either to `localized(...)`
        // re-introduces the bug, and re-introduces it here.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/IslaKit/Services/ScreenshotVault.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains(#"localized("Screenshot")"#),
            "the filename prefix must not be localized: the retention trim matches on it"
        )
        XCTAssertFalse(
            source.contains(#"localized("yyyy"#),
            "a DateFormatter pattern must never be a translatable string"
        )
    }

    /// A captured video is kept the same way a screenshot is: the vault writes
    /// it under its own name, and the usage and retention figures count it —
    /// otherwise a shelf full of recordings silently escapes the cap that was
    /// built for screenshots.
    func testMovieIsSavedWithRecordingPrefixAndCountsTowardUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ScreenshotVault(paths: AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        ))
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let saved = await vault.savedMovie(Data([9]), fileExtension: "mov", at: date)
        let url = try XCTUnwrap(saved)
        XCTAssertEqual(url.pathExtension, "mov")
        XCTAssertTrue(
            url.deletingPathExtension().lastPathComponent.hasPrefix("Screen Recording "),
            "a recording must carry the prefix the trim matches on, got \(url.lastPathComponent)"
        )
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))

        // The user's own movies are not the vault's: counted and trimmed never.
        let pictures = root.appendingPathComponent("pictures")
        try Data([7]).write(to: pictures.appendingPathComponent("Holiday.mov"))
        let usage = vault.usage()
        XCTAssertEqual(usage.files, 1)
    }

    /// A capture macOS wrote itself is the user's, whatever it is called.
    ///
    /// The vault used to claim any PNG named "Screenshot…" — which is exactly
    /// what Screenshot.app calls its own stills — so a user who pointed the
    /// system's save location at the folder Isla revealed had the oldest of
    /// their captures trashed past 200, and every one of them trashed by
    /// Clear (J-013). The system marks its captures; the vault now leaves
    /// anything carrying that mark alone.
    func testANativeCaptureInTheFolderIsNeverClaimed() throws {
        let (root, paths) = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.screenshotDirectory, withIntermediateDirectories: true)
        let native = paths.screenshotDirectory.appendingPathComponent("Screenshot 2026-10-11 at 15.04.05.png")
        try Data([1]).write(to: native)
        try Self.markAsSystemCapture(native)

        let vault = ScreenshotVault(paths: paths)
        XCTAssertEqual(vault.usage().files, 0, "a native capture must never count as the vault's own")
    }

    /// Building the vault must not create anything on disk.
    ///
    /// `init` created `~/Pictures/Isla` at every launch, with the feature off,
    /// and in every test that built a `NotchStores` — a folder the user never
    /// asked for, sitting in Pictures (J-013).
    func testInitCreatesNoFolder() {
        let (root, paths) = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = ScreenshotVault(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.screenshotDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.supportDirectory.appendingPathComponent("Screenshots").path))
    }

    /// A user who deletes the folder in Finder keeps getting screenshots
    /// saved. The folder was made once, in `init`, so every save after the
    /// deletion failed silently until the next launch (G-022).
    func testAWriteRecreatesADeletedFolder() async throws {
        let (root, paths) = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ScreenshotVault(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let firstSaved = await vault.saved(Data([1]), at: date)
        _ = try XCTUnwrap(firstSaved)
        try FileManager.default.removeItem(at: paths.screenshotDirectory)

        let secondSaved = await vault.saved(Data([2]), at: date.addingTimeInterval(5))
        let second = try XCTUnwrap(secondSaved, "a save after the folder was deleted must still land")
        XCTAssertEqual(second.deletingLastPathComponent().standardizedFileURL,
                       paths.screenshotDirectory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    /// Two captures stamped with the same second, started together. The
    /// collision loop ran on the concurrent global queue, so both writes could
    /// see the name free and the second `.atomic` write replaced the first
    /// (G-022). On one serial queue the second sees the first's file.
    func testTwoConcurrentSavesInOneSecondKeepBothFiles() async throws {
        let (root, paths) = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ScreenshotVault(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // Neither waits for the other: both are queued before either answers.
        async let a = vault.saved(Data([1]), at: date)
        async let b = vault.saved(Data([2]), at: date)
        let (first, second) = await (a, b)
        let one = try XCTUnwrap(first)
        let two = try XCTUnwrap(second)

        XCTAssertNotEqual(one, two)
        XCTAssertEqual(
            Set([try Data(contentsOf: one), try Data(contentsOf: two)]),
            Set([Data([1]), Data([2])])
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.screenshotDirectory.path)
        XCTAssertEqual(names.count, 2, "both captures must survive, got \(names)")
    }

    /// Clear removes what the vault wrote and nothing else: the user's own
    /// image, and a native capture that happens to share the vault's prefix,
    /// stay where they are. A file named the vault's way with no mark either
    /// way was written before the mark existed, and stays the vault's to
    /// manage — otherwise every capture saved by an older build would escape
    /// the cap for good.
    ///
    /// The discard seam stands in for the Trash: the test must never move
    /// files into the owner's.
    func testClearRemovesOnlyMarkedFiles() async throws {
        let (root, paths) = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let discarded = DiscardLog()
        let vault = ScreenshotVault(paths: paths, discard: { discarded.append($0) })
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let savedURL = await vault.saved(Data([1]), at: date)
        let ours = try XCTUnwrap(savedURL)
        let folder = paths.screenshotDirectory
        let native = folder.appendingPathComponent("Screenshot 2026-10-11 at 15.04.05.png")
        try Data([2]).write(to: native)
        try Self.markAsSystemCapture(native)
        let users = folder.appendingPathComponent("Holiday.png")
        try Data([3]).write(to: users)
        let legacy = folder.appendingPathComponent("Screenshot 2020-01-01 at 10.00.00.png")
        try Data([4]).write(to: legacy)

        XCTAssertEqual(vault.usage().files, 2)
        vault.clear()
        // The vault runs its work on one serial queue, so a save queued after
        // the clear answers only once the clear has finished.
        _ = await vault.saved(Data([5]), at: date.addingTimeInterval(60))

        XCTAssertEqual(
            Set(discarded.urls.map(\.lastPathComponent)),
            Set([ours.lastPathComponent, legacy.lastPathComponent])
        )
    }

    private static func temporaryPaths() -> (URL, AppPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        ))
    }

    /// The mark Screenshot.app leaves on every capture it writes.
    private static func markAsSystemCapture(_ url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let status = value.withUnsafeBytes { bytes in
            setxattr(url.path, CaptureMetadata.screenCaptureAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        XCTAssertEqual(status, 0, "the fixture needs the attribute set")
    }

    /// The stamp in the machine's own time zone, so the assertion above does
    /// not depend on where the test runs — the date rolls over with the zone.
    private func expectedStamp(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// What the discard seam was handed, from the vault's queue.
private final class DiscardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        stored.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private extension ScreenshotVault {
    /// `save` answers through a completion; tests want a value.
    func saved(_ png: Data, at date: Date) async -> URL? {
        await withCheckedContinuation { continuation in
            save(png, at: date) { continuation.resume(returning: $0) }
        }
    }

    func savedMovie(_ data: Data, fileExtension: String, at date: Date) async -> URL? {
        await withCheckedContinuation { continuation in
            saveMovie(data, fileExtension: fileExtension, at: date) { continuation.resume(returning: $0) }
        }
    }
}

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

private extension ScreenshotVault {
    /// `save` answers through a completion; tests want a value.
    func saved(_ png: Data, at date: Date) async -> URL? {
        await withCheckedContinuation { continuation in
            save(png, at: date) { continuation.resume(returning: $0) }
        }
    }
}

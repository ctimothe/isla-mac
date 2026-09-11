import XCTest
@testable import IslaKit

/// Screen recordings the system saved to disk, picked up without any copy
/// step: the shelf scans Screenshot.app's save location when it opens and
/// imports what finished since the feature first ran.
@MainActor
final class RecordingPickupTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ name: String, in folder: URL, modified daysAgo: Double = 0) throws {
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        if daysAgo > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)],
                ofItemAtPath: url.path
            )
        }
    }

    func testFreshRecordingIsOfferedOldestFirst() throws {
        let dir = try folder()
        try write("Screen Recording 2026-09-11 at 10.00.01.mov", in: dir)
        try write("Screen Recording 2026-09-11 at 10.00.02.mov", in: dir)

        let result = RecordingPickup.fresh(
            in: dir, since: Date().addingTimeInterval(-3600), seen: []
        )

        XCTAssertEqual(result.urls.map(\.lastPathComponent), [
            "Screen Recording 2026-09-11 at 10.00.01.mov",
            "Screen Recording 2026-09-11 at 10.00.02.mov",
        ])
    }

    /// Everything the scan meets is remembered, including what it does not
    /// offer: a recording older than the first run must not surface on a
    /// later open just because it was never marked.
    func testOldRecordingIsNeverOfferedYetNeverReconsidered() throws {
        let dir = try folder()
        try write("old.mov", in: dir, modified: 30)

        let first = RecordingPickup.fresh(in: dir, since: Date(), seen: [])
        XCTAssertTrue(first.urls.isEmpty)

        let second = RecordingPickup.fresh(
            in: dir, since: .distantPast, seen: first.seen
        )
        XCTAssertTrue(second.urls.isEmpty, "seen once means settled, whatever since says")
    }

    func testNonMoviesAreIgnored() throws {
        let dir = try folder()
        try write("notes.txt", in: dir)
        try write("shot.png", in: dir)
        try write("song.mp3", in: dir)

        let result = RecordingPickup.fresh(in: dir, since: .distantPast, seen: [])
        XCTAssertTrue(result.urls.isEmpty)
    }

    func testMissingFolderIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-never-created-\(UUID())")
        let result = RecordingPickup.fresh(in: missing, since: .distantPast, seen: [])
        XCTAssertTrue(result.urls.isEmpty)
    }

    func testConfiguredLocationWinsOverDesktop() throws {
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        let custom = dir.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try (["location": "~/Captures-test-unused"] as NSDictionary).write(to: plist)

        let resolved = RecordingPickup.screencaptureLocation(preferencesFile: plist)
        XCTAssertEqual(resolved, "~/Captures-test-unused")
    }

    func testMissingLocationFallsBackToDesktop() throws {
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        try (["showsCursor": true] as NSDictionary).write(to: plist)

        XCTAssertNil(RecordingPickup.screencaptureLocation(preferencesFile: plist))
        XCTAssertEqual(
            RecordingPickup.captureFolder().lastPathComponent, "Desktop",
            "no configured location means where the system saves by default"
        )
    }
}

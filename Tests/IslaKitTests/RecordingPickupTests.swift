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
            in: [dir], since: Date().addingTimeInterval(-3600), seen: []
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

        let first = RecordingPickup.fresh(in: [dir], since: Date(), seen: [])
        XCTAssertTrue(first.urls.isEmpty)

        let second = RecordingPickup.fresh(
            in: [dir], since: .distantPast, seen: first.seen
        )
        XCTAssertTrue(second.urls.isEmpty, "seen once means settled, whatever since says")
    }

    /// Anything that is not a capture is left where it is.
    ///
    /// A still now counts, so the rule that keeps a Desktop full of somebody's
    /// own pictures off the shelf is the capture *prefix* — `picture.png` is
    /// theirs, `Screenshot ….png` is the system's.
    func testOnlyCapturesAreOffered() throws {
        let dir = try folder()
        try write("notes.txt", in: dir)
        try write("picture.png", in: dir)
        try write("song.mp3", in: dir)
        try write("Screenshot 2026-09-21 at 10.00.01.png", in: dir)

        let result = RecordingPickup.fresh(in: [dir], since: .distantPast, seen: [])
        XCTAssertEqual(
            result.urls.map(\.lastPathComponent),
            ["Screenshot 2026-09-21 at 10.00.01.png"]
        )
    }

    /// A still saved to disk arrives on the shelf beside the recordings.
    ///
    /// Only clipboard images used to reach the shelf, so ⇧⌘4 to a file showed
    /// nothing at all while ⇧⌘5 did — one capture key working and its
    /// neighbour not, for no reason a person could see.
    func testStillsAndRecordingsArriveTogetherOldestFirst() throws {
        let dir = try folder()
        try write("Screenshot 2026-09-21 at 10.00.01.png", in: dir, modified: 2)
        try write("Screen Recording 2026-09-21 at 10.00.02.mov", in: dir, modified: 1)

        let result = RecordingPickup.fresh(in: [dir], since: .distantPast, seen: [])
        XCTAssertEqual(result.urls.map(\.lastPathComponent), [
            "Screenshot 2026-09-21 at 10.00.01.png",
            "Screen Recording 2026-09-21 at 10.00.02.mov",
        ])
    }

    /// A custom prefix set in Screenshot.app's options is honoured.
    func testACustomCaptureNameIsHonoured() throws {
        let dir = try folder()
        try write("Grab 2026-09-21 at 10.00.01.png", in: dir)
        let prefixes = RecordingPickup.capturePrefixes(customName: "Grab")
        let result = RecordingPickup.fresh(
            in: [dir], since: .distantPast, seen: [], prefixes: prefixes
        )
        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Grab 2026-09-21 at 10.00.01.png"])
    }

    /// Changing the save location must not orphan what is still in the old one.
    ///
    /// The scan used to look at the current folder and nowhere else, so a
    /// person who moved their captures mid-session lost everything already
    /// sitting where they used to go.
    func testCapturesInAPreviousFolderAreStillFound() throws {
        let old = try folder()
        let new = try folder()
        try write("Screen Recording 2026-09-21 at 09.00.00.mov", in: old, modified: 2)
        try write("Screenshot 2026-09-21 at 10.00.00.png", in: new, modified: 1)

        let result = RecordingPickup.fresh(in: [new, old], since: .distantPast, seen: [])
        XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)), [
            "Screen Recording 2026-09-21 at 09.00.00.mov",
            "Screenshot 2026-09-21 at 10.00.00.png",
        ])
    }

    /// And the folder list remembers where captures have been sent, so the
    /// next scan still looks in the one that was just left behind.
    func testTheFolderListRemembersWhereCapturesHaveBeenSent() throws {
        let suite = "isla-capture-folders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folders = RecordingPickup.captureFolders(defaults: defaults)
        XCTAssertFalse(folders.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: RecordingPickup.knownFoldersKey), folders.map(\.path),
            "what was scanned is written back, so a later change keeps it in the list"
        )
        // The Desktop is always in the list: it is where the system saves when
        // nothing is configured.
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true).path
        XCTAssertTrue(folders.map(\.path).contains(desktop))
    }

    func testMissingFolderIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-never-created-\(UUID())")
        let result = RecordingPickup.fresh(in: [missing], since: .distantPast, seen: [])
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
            RecordingPickup.captureFolder(preferencesFile: plist).lastPathComponent, "Desktop",
            "no configured location means where the system saves by default"
        )
    }
}

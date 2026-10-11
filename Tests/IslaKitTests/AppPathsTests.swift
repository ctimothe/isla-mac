import Foundation
import XCTest
@testable import IslaKit

final class AppPathsTests: XCTestCase {
    func testLivePathsUseOnlyIslaDirectories() {
        XCTAssertEqual(AppPaths.live.supportDirectory.lastPathComponent, "Isla")
        XCTAssertEqual(AppPaths.live.screenshotDirectory.lastPathComponent, "Isla")
        XCTAssertFalse(AppPaths.live.supportDirectory.path.contains("/Cyclop"))
        XCTAssertFalse(AppPaths.live.screenshotDirectory.path.contains("/Cyclop"))
    }

    func testSupportFileCreatesOnlyTheInjectedSupportDirectory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        )

        let file = paths.supportFile("notes.json")

        XCTAssertEqual(file, root.appendingPathComponent("support/notes.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("support").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pictures").path))
    }

    // MARK: - The weekly drop-inbox prune (F-019)

    /// Two week-old drop folders, `A` and `B`, each holding one file, under a
    /// temporary root. Returned with the root so the test can name what it
    /// keeps; nothing here touches the real support directory or the Trash.
    private func makeAgedInbox(now: Date) throws -> (root: URL, a: URL, b: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Dropped", isDirectory: true)
        let scratch = root.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        var folders: [URL] = []
        for name in ["A", "B"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("mail.pdf"))
            // After the file is written: writing into the folder moves its
            // modification date to now.
            try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: folder.path)
            folders.append(folder)
        }
        return (root, folders[0], folders[1])
    }

    func testPruneSkipsAFolderACardStillUses() throws {
        let now = Date()
        let inbox = try makeAgedInbox(now: now)
        var discarded: [URL] = []

        AppPaths.pruneDropInbox(
            root: inbox.root,
            keeping: [inbox.a.appendingPathComponent("mail.pdf")],
            now: now,
            discard: { discarded.append($0) }
        )

        XCTAssertEqual(discarded.map(\.lastPathComponent), ["B"])
    }

    /// The card's URL comes back from its bookmark resolved, and the root the
    /// prune lists need not be: a support folder reached through a symbolic
    /// link — a relocated Library, a home on another volume — names the same
    /// folder two ways. A plain comparison of the two would trash the very
    /// folder the card points into. (`/private/var` against `/var` is not
    /// this case: standardizing a file URL already folds those together.)
    func testPruneMatchesAKeptFileThroughAnotherSpellingOfItsPath() throws {
        let now = Date()
        let inbox = try makeAgedInbox(now: now)
        var discarded: [URL] = []
        let scratch = inbox.root.deletingLastPathComponent()
        let link = scratch.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        let linkedRoot = link.appendingPathComponent("Dropped", isDirectory: true)
        let resolved = inbox.a.appendingPathComponent("mail.pdf")
        let tidied = linkedRoot.appendingPathComponent("A/mail.pdf").standardizedFileURL
        XCTAssertNotEqual(tidied.path, resolved.standardizedFileURL.path,
                          "the kept URL must be spelled differently from the root for this test to mean anything")

        AppPaths.pruneDropInbox(
            root: linkedRoot,
            keeping: [resolved],
            now: now,
            discard: { discarded.append($0) }
        )

        XCTAssertEqual(discarded.map(\.lastPathComponent), ["B"])
    }

    /// A card whose file lives elsewhere — the Desktop, another drop root that
    /// merely shares a name prefix — protects nothing in the inbox.
    func testPruneStillDiscardsAgedFoldersNoCardUses() throws {
        let now = Date()
        let inbox = try makeAgedInbox(now: now)
        var discarded: [URL] = []
        let lookalike = URL(fileURLWithPath: inbox.root.path + "Elsewhere/A/mail.pdf")

        AppPaths.pruneDropInbox(
            root: inbox.root,
            keeping: [URL(fileURLWithPath: "/Users/someone/Desktop/mail.pdf"), lookalike],
            now: now,
            discard: { discarded.append($0) }
        )

        XCTAssertEqual(Set(discarded.map(\.lastPathComponent)), ["A", "B"])
    }

    /// A test process that reaches the prune with no recorder — through the
    /// stores, say — trashes nothing: the default is the owner's real Trash.
    func testPruneWithoutARecorderTrashesNothingInATestProcess() throws {
        let now = Date()
        let inbox = try makeAgedInbox(now: now)

        AppPaths.pruneDropInbox(root: inbox.root, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.b.path))
    }

    /// The week is still the rule for a folder no card uses: a fresh one stays.
    func testPruneLeavesAFolderYoungerThanAWeek() throws {
        let now = Date()
        let inbox = try makeAgedInbox(now: now)
        var discarded: [URL] = []

        AppPaths.pruneDropInbox(
            root: inbox.root,
            keeping: [],
            now: now.addingTimeInterval(-2 * 24 * 60 * 60),
            discard: { discarded.append($0) }
        )

        XCTAssertEqual(discarded, [])
    }
}

import Foundation
import XCTest
@testable import IslaKit

/// The local feed being watched (`UpdateFeedWatcher`): a publish lands in the
/// folder as a burst — an image, a signature, `release.json` renamed in — and
/// the island should hear of it once, a moment after the last write, and never
/// after the watcher has stopped.
@MainActor
final class UpdateFeedWatcherTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins until `condition` holds, for three seconds at most: a loaded
    /// machine delivers the kernel's event late, never early.
    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { spin(0.02) }
    }

    /// Written beside the folder and renamed in, as the publish script does.
    private func publish(_ name: String, in folder: URL) throws {
        let staged = folder.deletingLastPathComponent().appendingPathComponent(".\(name)-\(UUID().uuidString)")
        try Data(name.utf8).write(to: staged)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
    }

    func testABurstOfWritesIsOneChangeAfterTheLast() throws {
        let folder = try UpdateTestSupport.folder(self)
        var changes = 0
        let watcher = UpdateFeedWatcher(folder: folder, coalesce: 0.2) { changes += 1 }
        addTeardownBlock { @MainActor in watcher.stop() }
        XCTAssertTrue(watcher.start())
        try publish("Isla-0.3.0.1.dmg", in: folder)
        try publish("Isla-0.3.0.1.dmg.sig", in: folder)
        try publish("release.json", in: folder)
        spin(0.1)
        XCTAssertEqual(changes, 0, "still inside the burst's window")
        spin(until: { changes > 0 })
        spin(0.3)
        XCTAssertEqual(changes, 1, "one check for one publish")
        try publish("release.json", in: folder)
        spin(until: { changes > 1 })
        XCTAssertEqual(changes, 2, "the next publish is heard too, a replaced release included")
    }

    func testAStoppedWatcherHearsNothing() throws {
        let folder = try UpdateTestSupport.folder(self)
        var changes = 0
        let watcher = UpdateFeedWatcher(folder: folder, coalesce: 0.1) { changes += 1 }
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.isWatching)
        try publish("release.json", in: folder)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        spin(0.4)
        XCTAssertEqual(changes, 0, "a change pending when it stopped is dropped with it")
        try publish("release.json", in: folder)
        spin(0.3)
        XCTAssertEqual(changes, 0)
    }

    /// The descriptor follows the folder it was opened on. A feed removed and
    /// made again — `rm -rf .dev-updates`, then a publish — or renamed away and
    /// replaced was a folder nobody watched any more, and every build after it
    /// waited for the daily check. The watcher lets go and opens the path
    /// again, sooner at first and then less often, and checks once it has.
    func testAFeedRemovedOrRenamedAndMadeAgainIsWatchedAgain() throws {
        let fm = FileManager.default
        let folder = try UpdateTestSupport.folder(self).appendingPathComponent("feed", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var changes = 0
        let watcher = UpdateFeedWatcher(folder: folder, coalesce: 0.1, reopenDelay: 0.1) { changes += 1 }
        addTeardownBlock { @MainActor in watcher.stop() }
        XCTAssertTrue(watcher.start())

        try fm.removeItem(at: folder)
        spin(until: { !watcher.isWatching })
        XCTAssertFalse(watcher.isWatching, "let go of the removed folder")
        spin(0.35)
        XCTAssertFalse(watcher.isWatching, "nothing there to open yet")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        spin(until: { watcher.isWatching && changes > 0 })
        XCTAssertTrue(watcher.isWatching, "the folder made again is watched")
        let afterReopen = changes
        XCTAssertGreaterThan(afterReopen, 0, "and checked, since anything may be in it")
        try publish("release.json", in: folder)
        spin(until: { changes > afterReopen })
        XCTAssertGreaterThan(changes, afterReopen, "a publish into it is heard")

        let moved = folder.deletingLastPathComponent().appendingPathComponent("feed-old")
        try fm.moveItem(at: folder, to: moved)
        spin(until: { !watcher.isWatching })
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let beforeRename = changes
        spin(until: { watcher.isWatching && changes > beforeRename })
        try publish("release.json", in: folder)
        let afterRename = changes
        spin(until: { changes > afterRename })
        XCTAssertGreaterThan(changes, afterRename, "renamed away and replaced, the new folder is the one heard")
        watcher.stop()
        try fm.removeItem(at: folder)
        spin(0.4)
        XCTAssertFalse(watcher.isWatching, "a stopped watcher reopens nothing")
    }

    func testAFolderThatCannotBeOpenedIsNotWatched() throws {
        let folder = try UpdateTestSupport.folder(self).appendingPathComponent("missing")
        let watcher = UpdateFeedWatcher(folder: folder) {}
        XCTAssertFalse(watcher.start())
        XCTAssertFalse(watcher.isWatching)
    }

    /// A publish that lands while a check of the folder is still running must
    /// not be lost: the check runs once more when it is done. GitHub's button
    /// keeps its old rule — a press during a check is the same question.
    func testAChangeDuringACheckOfTheFolderChecksAgainAfterIt() async throws {
        let folder = try UpdateTestSupport.folder(self).resolvingSymlinksInPath()
        let check = UpdateCheck(fetch: { _ in throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, source: .localFeed(folder))
        check.check()
        XCTAssertEqual(check.state, .checking)
        check.check()
        XCTAssertTrue(check.checksAgainWhenDone)
        for _ in 0..<300 where check.state == .checking || check.checksAgainWhenDone {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(check.checksAgainWhenDone)
        XCTAssertNotEqual(check.state, .checking)

        let github = UpdateCheck(fetch: { _ in try await Task.sleep(for: .seconds(1)); throw URLError(.cancelled) }, currentVersion: { "0.3.0" }, source: .github)
        github.check()
        github.check()
        XCTAssertFalse(github.checksAgainWhenDone, "a second press on GitHub asks nothing more")
    }
}

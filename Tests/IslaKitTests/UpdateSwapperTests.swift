import Foundation
import XCTest
@testable import IslaKit

/// The swap, on real folders in a folder of the test's own. What matters is the
/// state a person is left in when it goes wrong: the installed path must hold an
/// app, whatever the failure. Failures are forced through the swapper's own
/// seams (`swap`, `replace`, `move`) and happen to real directories.
final class UpdateSwapperTests: XCTestCase {
    private struct Rig {
        let folder: URL
        let installed: URL
        let staged: URL
        var swapper = FileManagerSwapper()

        func marker(of app: URL) -> String? {
            try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
        }
        var beside: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    }

    private func rig() throws -> Rig {
        let folder = try UpdateTestSupport.folder(self)
        let apps = folder.appendingPathComponent("Apps", isDirectory: true)
        let staging = folder.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let installed = try UpdateTestSupport.tinyApp(in: apps, version: "1.0", build: "1", marker: "old")
        let staged = try UpdateTestSupport.tinyApp(in: staging, version: "1.1", build: "2", marker: "new")
        return Rig(folder: folder, installed: installed, staged: staged)
    }

    func testARealSwapPutsTheNewAppInPlaceAndRemovesTheOldOne() throws {
        let rig = try rig()
        try rig.swapper.replace(installed: rig.installed, with: rig.staged)
        XCTAssertEqual(rig.marker(of: rig.installed), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.staged.path), "the staged path held the old app, which is removed")
        XCTAssertEqual(UpdateTestSupport.run("/usr/bin/codesign", ["--verify", "--strict", rig.installed.path]).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.installed.deletingLastPathComponent().path), ["Isla.app"])
    }

    func testTheSwapIsOneExchangeNotAMoveAndAReplace() throws {
        var rig = try rig()
        var calls: [String] = []
        let real = rig.swapper.swap
        rig.swapper.swap = { staged, installed in calls.append("swap"); return real(staged, installed) }
        rig.swapper.replace = { _, _ in calls.append("replace") }
        rig.swapper.move = { _, _ in calls.append("move") }
        try rig.swapper.replace(installed: rig.installed, with: rig.staged)
        XCTAssertEqual(calls, ["swap"], "no fallback and no restore when the exchange works")
    }

    func testAFailedExchangeTouchesNothing() throws {
        var rig = try rig()
        rig.swapper.swap = { _, _ in EACCES }
        let before = UpdateTestSupport.fingerprint(of: rig.folder)
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(UpdateTestSupport.fingerprint(of: rig.folder), before)
        XCTAssertEqual(rig.marker(of: rig.installed), "old")
    }

    func testAVolumeThatCannotExchangeFallsBackToReplace() throws {
        for code in [ENOTSUP, EINVAL] {
            var rig = try rig()
            rig.swapper.swap = { _, _ in code }
            try rig.swapper.replace(installed: rig.installed, with: rig.staged)
            XCTAssertEqual(rig.marker(of: rig.installed), "new", "errno \(code)")
            XCTAssertEqual(UpdateTestSupport.run("/usr/bin/codesign", ["--verify", "--strict", rig.installed.path]).status, 0)
        }
    }

    /// `replaceItemAt` can fail with the original already moved aside; the
    /// failure here does exactly that, to the real folders.
    private func movingAsideThenFailing(
        _ rig: Rig, hide: URL, report: @escaping (URL) -> [String: Any]
    ) -> (URL, URL) throws -> Void {
        { installed, _ in
            try FileManager.default.moveItem(at: installed, to: hide)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: report(hide))
        }
    }

    func testAFallbackThatFailsAfterMovingTheOriginalAsidePutsItBack() throws {
        var rig = try rig()
        let hidden = rig.folder.appendingPathComponent("hidden-original.app")
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = movingAsideThenFailing(rig, hide: hidden) { [FileManagerSwapper.originalItemLocationKey: $0] }
        let before = UpdateTestSupport.fingerprint(of: rig.installed)
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(UpdateTestSupport.fingerprint(of: rig.installed), before, "the original is back, byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
        XCTAssertEqual(rig.marker(of: rig.staged), "new", "the staged copy is as it was")
    }

    func testTheOriginalIsFoundWhereverTheErrorSaysItWent() throws {
        for (label, key) in [("url key", NSURLErrorKey), ("path key", NSFilePathErrorKey)] {
            var rig = try rig()
            let hidden = rig.folder.appendingPathComponent("hidden-\(label).app")
            rig.swapper.swap = { _, _ in ENOTSUP }
            rig.swapper.replace = movingAsideThenFailing(rig, hide: hidden) { url in
                [key: key == NSFilePathErrorKey ? url.path as Any : url as Any]
            }
            XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged), label)
            XCTAssertEqual(rig.marker(of: rig.installed), "old", label)
        }
    }

    func testTheOriginalIsFoundInAnUnderlyingError() throws {
        var rig = try rig()
        let hidden = rig.folder.appendingPathComponent("hidden-underlying.app")
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = movingAsideThenFailing(rig, hide: hidden) { url in
            [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [FileManagerSwapper.originalItemLocationKey: url])]
        }
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(rig.marker(of: rig.installed), "old")
    }

    /// If putting it back fails too, the swapper still rethrows the first error
    /// and does not crash; the original stays where it is, untouched.
    func testARestoreThatFailsToo() throws {
        var rig = try rig()
        let hidden = rig.folder.appendingPathComponent("hidden-stuck.app")
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = movingAsideThenFailing(rig, hide: hidden) { [FileManagerSwapper.originalItemLocationKey: $0] }
        var moves = 0
        rig.swapper.move = { _, _ in moves += 1; throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(rig.marker(of: hidden), "old", "the original is not lost, only not back yet")
    }

    func testAFallbackThatFailsBeforeTouchingAnythingRestoresNothing() throws {
        var rig = try rig()
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        var moves = 0
        rig.swapper.move = { _, _ in moves += 1 }
        let before = UpdateTestSupport.fingerprint(of: rig.folder)
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(UpdateTestSupport.fingerprint(of: rig.folder), before)
    }

    /// If an error names the staged copy as where the original went, restoring
    /// from it would install the update without its check: it is never moved.
    func testTheStagedCopyIsNeverMovedIntoPlaceByARestore() throws {
        var rig = try rig()
        let hidden = rig.folder.appendingPathComponent("hidden.app")
        let staged = rig.staged
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = { installed, _ in
            try FileManager.default.moveItem(at: installed, to: hidden)
            throw NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
                FileManagerSwapper.originalItemLocationKey: staged,
                NSURLErrorKey: hidden,
            ])
        }
        var moved: [URL] = []
        let real = rig.swapper.move
        rig.swapper.move = { from, to in moved.append(from); try real(from, to) }
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(moved, [hidden], "only the original, found by the next place the error names")
        XCTAssertEqual(rig.marker(of: rig.installed), "old")
        XCTAssertEqual(rig.marker(of: rig.staged), "new")
    }

    func testAStagedPathReachedThroughASymlinkIsAlsoExcluded() throws {
        var rig = try rig()
        let link = rig.folder.appendingPathComponent("link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.staged)
        rig.swapper.swap = { _, _ in ENOTSUP }
        rig.swapper.replace = { installed, _ in
            try FileManager.default.removeItem(at: installed)
            throw NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [FileManagerSwapper.originalItemLocationKey: link])
        }
        var moves = 0
        rig.swapper.move = { _, _ in moves += 1 }
        XCTAssertThrowsError(try rig.swapper.replace(installed: rig.installed, with: rig.staged))
        XCTAssertEqual(moves, 0)
    }
}

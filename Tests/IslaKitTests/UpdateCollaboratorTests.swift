import Foundation
import XCTest
@testable import IslaKit

/// The parts of the production collaborators that are decisions rather than
/// system calls: what is asked of `hdiutil`, how its answer is read, which
/// entry on the volume is the app, which redirects are followed, and exactly
/// what the relaunch script is.
@MainActor
final class UpdateCollaboratorTests: XCTestCase {

    // MARK: hdiutil

    func testTheDiskImageIsAttachedReadOnlyUnbrowsedAndUnopened() {
        let arguments = HdiutilDiskImage.attachArguments(
            image: URL(fileURLWithPath: "/tmp/x y/Isla.dmg"), scratch: URL(fileURLWithPath: "/tmp/x y")
        )
        XCTAssertEqual(arguments, [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
            "-mountrandom", "/tmp/x y", "-plist", "/tmp/x y/Isla.dmg",
        ], "an argument array: a space in a path stays inside its one argument")
    }

    func testTheMountPointIsReadFromHdiutilsPlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk4</string></dict>
          <dict><key>content-hint</key><string>Apple_HFS</string><key>dev-entry</key><string>/dev/disk4s1</string>
                <key>mount-point</key><string>/private/tmp/scratch/dmg.AbC123</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(HdiutilDiskImage.mountPoints(in: Data(plist.utf8)), [URL(fileURLWithPath: "/private/tmp/scratch/dmg.AbC123", isDirectory: true)])
        XCTAssertEqual(HdiutilDiskImage.mountPoints(in: Data("not a plist".utf8)), [])
        XCTAssertEqual(HdiutilDiskImage.mountPoints(in: Data()), [])
        let none = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>system-entities</key><array/></dict></plist>"
        XCTAssertEqual(HdiutilDiskImage.mountPoints(in: Data(none.utf8)), [])
    }

    // MARK: The app on the volume

    func testExactlyOneRealIslaAppAtTheRootIsFound() throws {
        let volume = try UpdateTestSupport.folder(self)
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("Isla.app"), withIntermediateDirectories: true)
        // The usual company on a disk image: an Applications link and a folder.
        try FileManager.default.createSymbolicLink(atPath: volume.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        try FileManager.default.createDirectory(at: volume.appendingPathComponent(".background"), withIntermediateDirectories: true)
        XCTAssertEqual(try DittoUpdateStager.findApp(in: volume).lastPathComponent, "Isla.app")
    }

    func testASymlinkNamedIslaAppIsRefused() throws {
        let volume = try UpdateTestSupport.folder(self)
        let elsewhere = try UpdateTestSupport.folder(self)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("Real.app"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: volume.appendingPathComponent("Isla.app").path, withDestinationPath: elsewhere.appendingPathComponent("Real.app").path
        )
        XCTAssertThrowsError(try DittoUpdateStager.findApp(in: volume))
    }

    func testNoAppOrAFileOrAnotherNameIsRefused() throws {
        let empty = try UpdateTestSupport.folder(self)
        XCTAssertThrowsError(try DittoUpdateStager.findApp(in: empty))
        let file = try UpdateTestSupport.folder(self)
        try Data().write(to: file.appendingPathComponent("Isla.app"))
        XCTAssertThrowsError(try DittoUpdateStager.findApp(in: file), "a file is not a bundle")
        let other = try UpdateTestSupport.folder(self)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Folder/Isla.app"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try DittoUpdateStager.findApp(in: other), "only the volume's root counts")
        let wrongCase = try UpdateTestSupport.folder(self)
        try FileManager.default.createDirectory(at: wrongCase.appendingPathComponent("isla.app"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try DittoUpdateStager.findApp(in: wrongCase), "exactly that spelling")
    }

    // MARK: The wire

    func testOnlyHTTPSRedirectsAreFollowed() {
        XCTAssertTrue(URLSessionUpdateDownloader.allowsRedirect(to: URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertFalse(URLSessionUpdateDownloader.allowsRedirect(to: URL(string: "http://objects.githubusercontent.com/x")))
        XCTAssertFalse(URLSessionUpdateDownloader.allowsRedirect(to: URL(string: "file:///etc/passwd")))
        XCTAssertFalse(URLSessionUpdateDownloader.allowsRedirect(to: nil))
    }

    /// The downloader goes through the same private configuration as every other
    /// request: nothing cached, no cookies, no credentials.
    func testTheDownloadUsesThePrivateConfiguration() {
        let configuration = PrivateNetwork.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(URLSessionUpdateDownloader().configuration().urlCache, nil)
    }

    // MARK: The relaunch

    /// The script is a constant. The path and the process id are arguments to
    /// it, so no character in an install path can change what runs.
    func testTheRelaunchScriptTakesItsInputsAsArguments() {
        XCTAssertEqual(
            ShellRelauncher.script,
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#
        )
        let hostile = URL(fileURLWithPath: "/Applications/Is'la \"; rm -rf ~; \".app")
        let arguments = ShellRelauncher.arguments(processID: 123, installed: hostile)
        XCTAssertEqual(arguments, ["-c", ShellRelauncher.script, "sh", "123", hostile.path])
        XCTAssertFalse(ShellRelauncher.script.contains("rm"))
    }

    /// The relaunch ends this process through the same call Quit uses, and only
    /// after the shell has been started.
    func testTheRelauncherQuitsThroughTheInjectedTerminate() {
        var terminated = 0
        // `true` ignores its arguments, so the real shell and the real `open`
        // never run.
        let relauncher = ShellRelauncher(terminate: { terminated += 1 }, shell: "/usr/bin/true")
        relauncher.relaunch(installed: URL(fileURLWithPath: "/nonexistent/Isla.app"), processID: 2_000_000_000)
        XCTAssertEqual(terminated, 1)
    }
}

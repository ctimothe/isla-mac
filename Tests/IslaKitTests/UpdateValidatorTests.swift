import Foundation
import XCTest
@testable import IslaKit

/// The check on the staged copy, the last thing standing between a signed disk
/// image and the app being replaced. Real tiny bundles, really code-signed.
@MainActor
final class UpdateValidatorTests: XCTestCase {
    private let page = URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v1.1")!

    private func validator(version: String = "1.0", build: String = "1") -> BundleUpdateValidator {
        BundleUpdateValidator(runningVersion: version, runningBuild: build)
    }

    private func release(_ version: String = "1.1") -> UpdateCheck.Release {
        UpdateCheck.Release(version: version, page: page)
    }

    private func result(_ app: URL, running: BundleUpdateValidator? = nil, release: UpdateCheck.Release? = nil) async -> UpdateValidationError? {
        do {
            try await (running ?? validator()).validate(app, release: release ?? self.release())
            return nil
        } catch {
            return error as? UpdateValidationError
        }
    }

    func testASignedNewerIslaPasses() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        let outcome = await result(app)
        XCTAssertNil(outcome)
    }

    func testAnotherBundleIdentifierIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, bundleID: "com.example.notisla", version: "1.1", build: "2")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .wrongIdentifier)
    }

    func testAVersionOtherThanTheAdvertisedOneIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.2", build: "2")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .wrongVersion, "the image holds 1.2, the release said 1.1")
    }

    func testTheSameVersionIsNotAnUpdate() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.0", build: "2")
        let outcome = await result(app, release: release("1.0"))
        XCTAssertEqual(outcome, .notNewer)
    }

    func testAnOlderVersionIsNotAnUpdate() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "0.9", build: "9")
        let outcome = await result(app, release: release("0.9"))
        XCTAssertEqual(outcome, .notNewer, "a downgrade is not an update, whatever its build says")
    }

    func testABuildThatIsNotGreaterIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        for build in ["1", "0"] {
            let app = try UpdateTestSupport.tinyApp(in: folder, name: "B\(build).app", version: "1.1", build: build)
            let outcome = await result(app)
            XCTAssertEqual(outcome, .buildNotNewer, "build \(build) against a running 1")
        }
    }

    func testABuildThatIsNotANumberIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "two")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .buildNotNewer)
    }

    func testAnUnsignedBundleIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2", signing: .none)
        let outcome = await result(app)
        XCTAssertEqual(outcome, .signatureInvalid)
    }

    func testABundleChangedAfterSigningIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2", marker: "signed")
        let passes = await result(app)
        XCTAssertNil(passes)
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        let outcome = await result(app)
        XCTAssertEqual(outcome, .signatureInvalid)
    }

    func testAFileThatIsNotABundleIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let empty = folder.appendingPathComponent("Isla.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let outcome = await result(empty)
        XCTAssertEqual(outcome, .unreadable)
        let missing = await result(folder.appendingPathComponent("Nope.app"))
        XCTAssertEqual(missing, .unreadable)
    }

    /// Sparkle's rule for certificate rotation: a new signing identity is fine,
    /// because the Ed25519 signature on the image is the gate. An ad-hoc build
    /// signed by a different run is a different identity and still passes.
    func testADifferentSigningIdentityIsAllowed() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        let again = try UpdateTestSupport.tinyApp(in: folder, name: "Again.app", version: "1.1", build: "2", marker: "other")
        let first = await result(app)
        let second = await result(again)
        XCTAssertNil(first)
        XCTAssertNil(second)
    }
}
